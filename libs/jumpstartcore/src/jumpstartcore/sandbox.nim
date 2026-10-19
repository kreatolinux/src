## Fail-closed sandbox (§13.8).
##
## Two layers:
##
## * Policy, which runs in the parent before `fork`: `validateSandbox` and
##   `prepareSandbox` check paths and platform support and produce a
##   `PreparedSandbox`. Every refusal is a `SandboxError` (`E_SANDBOX`).
## * Application, which runs in the child between `fork` and `execve`. It is
##   implemented in C below, uses only async-signal-safe system calls, does not
##   allocate, and is driven by `spawn.nim` through the `sandboxChild*`
##   procedures. Every failure is reported to the parent through the spawn
##   status pipe and the child exits without executing anything.
##
## `enterSandbox` with an injected `SandboxSystem` remains for testing the
## ordering policy. The default system refuses: the sandbox is applied only by
## the spawn layer, and nothing ever runs unsandboxed.
import std/[algorithm, os, sets, strutils]
import posix

type
  SandboxError* = object of CatchableError
  SandboxConfig* = object
    stateDir*, runtimeDir*: string
    writablePaths*: seq[string]
    workingDirectory*: string
    network*: bool
    forbiddenRoots*: seq[string]
      ## §13.1: in system mode `writable_paths` MUST NOT name a path under a
      ## home directory or another core's per-core directories. Callers list
      ## those roots here.
  SandboxSystem* = object
    available*: proc(): bool {.closure.}
    exists*: proc(path: string): bool {.closure.}
    isDir*: proc(path: string): bool {.closure.}
    unshareMountPidIpcUts*: proc() {.closure.}
    unshareNetwork*: proc() {.closure.}
    makeMountsPrivate*: proc() {.closure.}
    remountRootReadOnly*: proc() {.closure.}
    mountPrivateTmp*: proc() {.closure.}
    exposeWritable*: proc(path: string) {.closure.}
    bringLoopbackUp*: proc() {.closure.}
    dropAllCapabilities*: proc() {.closure.}
    setNoNewPrivileges*: proc() {.closure.}
    installDenySeccomp*: proc(syscalls: openArray[string]) {.closure.}
    changeDirectory*: proc(path: string) {.closure.}
  PreparedSandbox* = object
    ## Validated sandbox, ready to be applied in a child.
    writable*: seq[string]        ## existing writable paths, sorted
    workingDirectory*: string
    network*: bool
    userNamespace*: bool          ## unprivileged mode (§7.4 item 10)
    outerUid*, outerGid*: uint32  ## identity mapped into the user namespace

const DeniedSandboxSyscalls* = [
  "mount", "umount2", "pivot_root", "swapon", "swapoff", "reboot",
  "kexec_load", "kexec_file_load", "init_module", "finit_module",
  "delete_module"]

proc fail(message: string) {.noreturn.} =
  raise newException(SandboxError, message)

proc checkedAbsolute(path, label: string): string =
  if path.len == 0 or not path.isAbsolute or '\0' in path:
    fail(label & " must be an absolute path")
  for part in path.split({'/', '\\'}):
    if part == "..": fail(label & " must not contain '..'")
  result = normalizedPath(path)

proc containsPath(parent, child: string): bool =
  if parent == "/": return true
  child == parent or child.startsWith(parent & DirSep)

proc resolvedPath(path: string): string =
  ## `path` with every symbolic link in its longest existing prefix resolved
  ## (`realpath`), the not-yet-existing rest appended unchanged. A link that
  ## cannot be resolved (dangling, loop) fails closed: it could point anywhere
  ## once its target appears.
  var existing = path
  var tail: seq[string]
  var st: Stat
  while existing != "/" and lstat(existing.cstring, st) != 0:
    let (head, name) = splitPath(existing)
    tail.add name
    existing = if head.len == 0: "/" else: head
  var buffer: array[4096 + 1, char]
  if realpath(existing.cstring, cast[cstring](addr buffer[0])).isNil:
    fail("cannot resolve " & existing & ": " & osErrorMsg(osLastError()))
  result = $cast[cstring](addr buffer[0])
  for i in countdown(tail.high, 0): result = result / tail[i]

proc filesystemSystem*(): SandboxSystem =
  ## Path checks only; enough for `validateSandbox` and `prepareSandbox`.
  result.exists = proc(path: string): bool = fileExists(path) or dirExists(path)
  result.isDir = proc(path: string): bool = dirExists(path)

proc writableSandboxPaths*(config: SandboxConfig; sys: SandboxSystem): seq[string] =
  ## Validate configured writable paths and return existing paths to expose.
  ## §13.8: a state directory or `writable_paths` entry that does not exist
  ## yet is skipped, not created.
  if sys.exists.isNil or sys.isDir.isNil: fail("filesystem abstraction unavailable")
  var forbidden: seq[string]
  for root in config.forbiddenRoots:
    let checked = checkedAbsolute(root, "forbidden root")
    forbidden.add checked
    let resolved = resolvedPath(checked)   # a root that is itself reached via a link
    if resolved != checked: forbidden.add resolved
  var seen = initHashSet[string]()
  for pair in [(config.stateDir, "state directory"),
               (config.runtimeDir, "runtime directory")]:
    if pair[0].len > 0:
      let path = checkedAbsolute(pair[0], pair[1])
      if path == "/": fail("filesystem root cannot be writable")
      if sys.exists(path):
        if not sys.isDir(path): fail(pair[1] & " is not a directory")
        if path notin seen: seen.incl(path); result.add(path)
  for raw in config.writablePaths:
    let path = checkedAbsolute(raw, "writable path")
    if path == "/": fail("filesystem root cannot be writable")
    # §13.1, §13.8: the check is on where the path really leads, so a symbolic
    # link below the core's directories into /home or another core's
    # directories is refused, as is a lexical path under a forbidden root.
    let real = if forbidden.len > 0: resolvedPath(path) else: path
    for root in forbidden:
      if containsPath(root, path) or containsPath(root, real):
        fail("writable path is under a forbidden root: " & path &
          (if real != path: " (resolves to " & real & ")" else: ""))
    if not sys.exists(path): continue
    if path notin seen: seen.incl(path); result.add(path)
  result.sort(system.cmp[string])

const PrivateTmp* = "/tmp"
  ## §13.8: the sandbox has a private, writable `/tmp`.

proc validateSandbox*(config: SandboxConfig; sys: SandboxSystem): seq[string] =
  ## §13.1: under `sandbox: true` the working directory MUST be within a
  ## writable path: an existing state, runtime, or `writable_paths` entry,
  ## or the private `/tmp` itself (its other contents are not visible).
  result = writableSandboxPaths(config, sys)
  let working = checkedAbsolute(
    if config.workingDirectory.len == 0: "/" else: config.workingDirectory,
    "working directory")
  var writable = working == PrivateTmp
  for path in result:
    if containsPath(path, working): writable = true
  if not writable:
    fail("working directory must be within an existing writable path")
  if not sys.exists(working) or not sys.isDir(working):
    fail("working directory does not exist or is not a directory")

proc requireOperations(sys: SandboxSystem) =
  if sys.available.isNil or sys.unshareMountPidIpcUts.isNil or
      sys.unshareNetwork.isNil or sys.makeMountsPrivate.isNil or
      sys.remountRootReadOnly.isNil or sys.mountPrivateTmp.isNil or
      sys.exposeWritable.isNil or sys.bringLoopbackUp.isNil or
      sys.dropAllCapabilities.isNil or sys.setNoNewPrivileges.isNil or
      sys.installDenySeccomp.isNil or sys.changeDirectory.isNil:
    fail("sandbox system-call abstraction is incomplete")

proc enterSandbox*(config: SandboxConfig; sys: SandboxSystem) =
  ## Ordering policy with injected operations (tests). Any missing feature or
  ## failed callback raises `SandboxError`, which callers report as
  ## `E_SANDBOX`.
  requireOperations(sys)
  if not sys.available(): fail("complete sandbox support is unavailable")
  let writable = validateSandbox(config, sys) # validate before mutating process state
  let working = normalizedPath(
    if config.workingDirectory.len == 0: "/" else: config.workingDirectory)
  try:
    sys.unshareMountPidIpcUts()
    if not config.network:
      sys.unshareNetwork()
    sys.makeMountsPrivate()
    sys.remountRootReadOnly()
    sys.mountPrivateTmp()
    for path in writable: sys.exposeWritable(path)
    if not config.network: sys.bringLoopbackUp()
    sys.dropAllCapabilities()
    sys.setNoNewPrivileges()
    sys.installDenySeccomp(DeniedSandboxSyscalls)
    sys.changeDirectory(working)
  except SandboxError:
    raise
  except CatchableError as error:
    fail("sandbox setup failed: " & error.msg)

proc defaultSandboxSystem*(): SandboxSystem =
  ## In-process application is not supported: the sandbox must be entered
  ## between `fork` and `execve` (spawn layer). Every step refuses, so
  ## `enterSandbox(config, defaultSandboxSystem())` always fails closed.
  result = filesystemSystem()
  result.available = proc(): bool = false
  let refuse = proc() = fail("the sandbox is applied only by the spawn layer")
  result.unshareMountPidIpcUts = refuse
  result.unshareNetwork = refuse
  result.makeMountsPrivate = refuse
  result.remountRootReadOnly = refuse
  result.mountPrivateTmp = refuse
  result.exposeWritable = proc(path: string) = refuse()
  result.bringLoopbackUp = refuse
  result.dropAllCapabilities = refuse
  result.setNoNewPrivileges = refuse
  result.installDenySeccomp = proc(syscalls: openArray[string]) = refuse()
  result.changeDirectory = proc(path: string) = refuse()

# ---------------------------------------------------------------------------
# Child-side application (Linux)

type
  SandboxStep* = enum
    ## Identifies the failing step in the spawn status report.
    sbNone, sbUnshare, sbSetgroups, sbUidMap, sbGidMap, sbPrivate, sbCapture,
    sbReadOnly, sbTmp, sbAttach, sbLoopback, sbPidNamespace, sbBounding,
    sbCapabilities, sbAmbient, sbNoNewPrivs, sbSeccomp, sbUnavailable

when defined(linux):
  {.emit: """
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <linux/audit.h>
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <net/if.h>
#include <sched.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>
#ifndef AUDIT_ARCH_X86_64
#define AUDIT_ARCH_X86_64 0xC000003E
#endif
#ifndef AUDIT_ARCH_AARCH64
#define AUDIT_ARCH_AARCH64 0xC00000B7
#endif
#ifndef SYS_mount_setattr
#define SYS_mount_setattr 442
#endif
#ifndef SYS_open_tree
#define SYS_open_tree 428
#endif
#ifndef SYS_move_mount
#define SYS_move_mount 429
#endif
#ifndef AT_RECURSIVE
#define AT_RECURSIVE 0x8000
#endif
#ifndef OPEN_TREE_CLONE
#define OPEN_TREE_CLONE 1
#endif
#ifndef OPEN_TREE_CLOEXEC
#define OPEN_TREE_CLOEXEC O_CLOEXEC
#endif
#ifndef MOVE_MOUNT_F_EMPTY_PATH
#define MOVE_MOUNT_F_EMPTY_PATH 0x00000004
#endif
#define JS_MOUNT_ATTR_RDONLY 0x00000001
struct js_mount_attr { uint64_t attr_set, attr_clr, propagation, userns_fd; };
struct js_cap_header { uint32_t version; int pid; };
struct js_cap_data { uint32_t effective, permitted, inheritable; };
#define JS_CAP_V3 0x20080522
#define JS_MAX_WRITABLE 64

typedef struct js_sandbox {
  int network;
  int userns;
  unsigned int outer_uid, outer_gid;
  int nwritable;
  const char *const *writable;
} js_sandbox;

static int js_sb_write_file(const char *path, const char *data) {
  int fd = open(path, O_WRONLY | O_CLOEXEC);
  if (fd < 0) return errno;
  size_t len = strlen(data);
  ssize_t n = write(fd, data, len);
  int err = (n == (ssize_t)len) ? 0 : (n < 0 ? errno : EIO);
  close(fd);
  return err;
}

static void js_sb_utoa(unsigned int v, char *out) {
  char tmp[16]; int n = 0;
  do { tmp[n++] = (char)('0' + v % 10); v /= 10; } while (v);
  for (int i = 0; i < n; i++) out[i] = tmp[n - 1 - i];
  out[n] = 0;
}

static int js_sb_map_line(unsigned int id, char *line) {
  /* "ID ID 1\n": the outer identity maps onto itself. */
  char num[16]; js_sb_utoa(id, num);
  size_t a = strlen(num);
  memcpy(line, num, a); line[a] = ' ';
  memcpy(line + a + 1, num, a); line[2 * a + 1] = ' ';
  line[2 * a + 2] = '1'; line[2 * a + 3] = '\n'; line[2 * a + 4] = 0;
  return 0;
}

static int js_sb_under_tmp(const char *p) {
  return strncmp(p, "/tmp", 4) == 0 && (p[4] == 0 || p[4] == '/');
}

static int js_sb_mkdirs(const char *p) {
  /* Create mount points inside the private /tmp (never on the host). */
  char buf[4096]; size_t len = strlen(p);
  if (len >= sizeof(buf)) return ENAMETOOLONG;
  memcpy(buf, p, len + 1);
  for (size_t i = 5; i <= len; i++) {
    if (buf[i] == '/' || buf[i] == 0) {
      char saved = buf[i]; buf[i] = 0;
      if (mkdir(buf, 0755) < 0 && errno != EEXIST) return errno;
      buf[i] = saved;
    }
  }
  return 0;
}

/* Runs in the forked child, as the spawning identity. Creates the namespaces
   and the mount layout of section 13.8. */
static int js_sb_namespaces(const void *raw, int *step) {
  const js_sandbox *c = (const js_sandbox *)raw;
  int trees[JS_MAX_WRITABLE];
  if (c->nwritable > JS_MAX_WRITABLE) { *step = 1; return E2BIG; }
  unsigned long flags = CLONE_NEWNS | CLONE_NEWPID | CLONE_NEWIPC | CLONE_NEWUTS;
  if (!c->network) flags |= CLONE_NEWNET;
  if (c->userns) flags |= CLONE_NEWUSER;
  *step = 1;
  if (unshare((int)flags) < 0) return errno;
  if (c->userns) {
    char line[48]; int err;
    *step = 2;
    if ((err = js_sb_write_file("/proc/self/setgroups", "deny"))) return err;
    *step = 3; js_sb_map_line(c->outer_uid, line);
    if ((err = js_sb_write_file("/proc/self/uid_map", line))) return err;
    *step = 4; js_sb_map_line(c->outer_gid, line);
    if ((err = js_sb_write_file("/proc/self/gid_map", line))) return err;
  }
  *step = 5;
  if (mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL) < 0) return errno;
  /* Clone each writable path before the root becomes read-only, so the
     detached copies stay writable. */
  *step = 6;
  for (int i = 0; i < c->nwritable; i++) {
    trees[i] = (int)syscall(SYS_open_tree, AT_FDCWD, c->writable[i],
                            OPEN_TREE_CLONE | OPEN_TREE_CLOEXEC);
    if (trees[i] < 0) { int e = errno; for (int j = 0; j < i; j++) close(trees[j]); return e; }
  }
  struct js_mount_attr ro; memset(&ro, 0, sizeof(ro)); ro.attr_set = JS_MOUNT_ATTR_RDONLY;
  *step = 7;
  if (syscall(SYS_mount_setattr, AT_FDCWD, "/", AT_RECURSIVE, &ro, sizeof(ro)) < 0) return errno;
  *step = 8;
  if (mount("tmpfs", "/tmp", "tmpfs", MS_NOSUID | MS_NODEV, "mode=1777") < 0) return errno;
  *step = 9;
  for (int i = 0; i < c->nwritable; i++) {
    int err;
    if (js_sb_under_tmp(c->writable[i]) && (err = js_sb_mkdirs(c->writable[i]))) return err;
    if (syscall(SYS_move_mount, trees[i], "", AT_FDCWD, c->writable[i],
                MOVE_MOUNT_F_EMPTY_PATH) < 0) return errno;
    close(trees[i]);
  }
  if (!c->network) {
    *step = 10;
    int f = socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (f < 0) return errno;
    struct ifreq r; memset(&r, 0, sizeof(r)); strncpy(r.ifr_name, "lo", IFNAMSIZ - 1);
    if (ioctl(f, SIOCGIFFLAGS, &r) < 0) { int e = errno; close(f); return e; }
    r.ifr_flags |= IFF_UP | IFF_RUNNING;
    if (ioctl(f, SIOCSIFFLAGS, &r) < 0) { int e = errno; close(f); return e; }
    close(f);
  }
  *step = 0;
  return 0;
}

static void js_sb_close_from(int lowest) {
#ifdef SYS_close_range
  if (syscall(SYS_close_range, (unsigned)lowest, ~0U, 0) == 0) return;
#endif
  long max = sysconf(_SC_OPEN_MAX);
  if (max < 0 || max > 65536) max = 65536;
  for (int fd = lowest; fd < max; fd++) close(fd);
}

static void js_sb_wait_and_exit(pid_t child) {
  int status;
  for (;;) {
    pid_t p = waitpid(-1, &status, 0);
    if (p < 0) { if (errno == EINTR) continue; _exit(125); }
    if (p == child) {
      if (WIFEXITED(status)) _exit(WEXITSTATUS(status));
      if (WIFSIGNALED(status)) _exit(128 + WTERMSIG(status));
    }
  }
}

/* The PID namespace takes effect for children. The calling process (A, in the
   host namespace, registered with the reaper) forks B, which is PID 1 of the
   new namespace and reaps everything in it; B forks C, which returns 0 and goes
   on to execute the program. A and B block catchable signals and only wait, so
   signals sent to the process group reach C directly, while SIGKILL to the group
   still ends all three. When B exits the kernel kills the rest of the
   namespace. Returns an errno on failure (in the caller); never returns in A or
   B. */
static int js_sb_fork_pid_namespace(void) {
  sigset_t all; sigfillset(&all);
  if (sigprocmask(SIG_SETMASK, &all, NULL) < 0) return errno;
  pid_t b = fork();
  if (b < 0) return errno;
  if (b > 0) { js_sb_close_from(0); js_sb_wait_and_exit(b); }
  pid_t c = fork();
  if (c < 0) return errno;
  if (c > 0) { js_sb_close_from(0); js_sb_wait_and_exit(c); }
  sigset_t none; sigemptyset(&none);
  if (sigprocmask(SIG_SETMASK, &none, NULL) < 0) return errno;
  return 0;
}

/* Drop the bounding and ambient sets. Needs CAP_SETPCAP, so it runs before any
   identity change (as root, or with full capabilities in the new user
   namespace). */
static int js_sb_drop_bounding(int *step) {
  int last = 63;
  int f = open("/proc/sys/kernel/cap_last_cap", O_RDONLY | O_CLOEXEC);
  if (f >= 0) {
    char b[16] = {0}; ssize_t n = read(f, b, sizeof(b) - 1); close(f);
    if (n > 0) { last = 0; for (ssize_t i = 0; i < n && b[i] >= '0' && b[i] <= '9'; i++) last = last * 10 + (b[i] - '0'); }
  }
  *step = 12;
  for (int cap = 0; cap <= last; cap++)
    if (prctl(PR_CAPBSET_DROP, cap, 0, 0, 0) < 0 && errno != EINVAL) return errno;
  *step = 14;
  if (prctl(PR_CAP_AMBIENT, PR_CAP_AMBIENT_CLEAR_ALL, 0, 0, 0) < 0) return errno;
  *step = 0;
  return 0;
}

#define JD(n) BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K,(n),0,1),BPF_STMT(BPF_RET|BPF_K,SECCOMP_RET_ERRNO|EPERM)

/* Clear the remaining capability sets, set no_new_privs, and install the
   seccomp filter. Runs last, after the identity change. */
static int js_sb_lockdown(int *step) {
  struct js_cap_header h; struct js_cap_data d[2];
  memset(&h, 0, sizeof(h)); memset(d, 0, sizeof(d)); h.version = JS_CAP_V3;
  *step = 13;
  if (syscall(SYS_capset, &h, d) < 0) return errno;
  *step = 14;
  if (prctl(PR_CAP_AMBIENT, PR_CAP_AMBIENT_CLEAR_ALL, 0, 0, 0) < 0) return errno;
  *step = 15;
  if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) < 0) return errno;
  struct sock_filter code[] = {
    BPF_STMT(BPF_LD|BPF_W|BPF_ABS, offsetof(struct seccomp_data, arch)),
#if defined(__x86_64__)
    BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, AUDIT_ARCH_X86_64, 1, 0),
#elif defined(__aarch64__)
    BPF_JUMP(BPF_JMP|BPF_JEQ|BPF_K, AUDIT_ARCH_AARCH64, 1, 0),
#else
#error unsupported architecture for the section 13.8 seccomp filter
#endif
    BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_KILL_PROCESS),
    BPF_STMT(BPF_LD|BPF_W|BPF_ABS, offsetof(struct seccomp_data, nr)),
#if defined(__x86_64__)
    /* x32 system calls carry bit 30 and would bypass the checks below. */
    BPF_JUMP(BPF_JMP|BPF_JGE|BPF_K, 0x40000000, 0, 1),
    BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ERRNO|EPERM),
#endif
    JD(__NR_mount), JD(__NR_umount2), JD(__NR_pivot_root), JD(__NR_swapon),
    JD(__NR_swapoff), JD(__NR_reboot), JD(__NR_kexec_load),
    JD(__NR_kexec_file_load), JD(__NR_init_module), JD(__NR_finit_module),
    JD(__NR_delete_module),
#ifdef __NR_open_tree
    JD(__NR_open_tree),
#endif
#ifdef __NR_move_mount
    JD(__NR_move_mount),
#endif
#ifdef __NR_fsmount
    JD(__NR_fsmount),
#endif
#ifdef __NR_mount_setattr
    JD(__NR_mount_setattr),
#endif
    BPF_STMT(BPF_RET|BPF_K, SECCOMP_RET_ALLOW)};
  struct sock_fprog prog = {(unsigned short)(sizeof(code) / sizeof(code[0])), code};
  *step = 16;
  if (syscall(SYS_seccomp, SECCOMP_SET_MODE_FILTER, 0, &prog) < 0) return errno;
  *step = 0;
  return 0;
}

/* Kernel feature probe, run in the parent: ENOSYS means unsupported. */
static int js_sb_probe(void) {
  struct js_mount_attr a; memset(&a, 0, sizeof(a));
  if (syscall(SYS_mount_setattr, -1, "", 0, &a, sizeof(a)) < 0 && errno == ENOSYS) return ENOSYS;
  if (syscall(SYS_open_tree, -1, "", 0) < 0 && errno == ENOSYS) return ENOSYS;
  if (syscall(SYS_move_mount, -1, "", -1, "", 0) < 0 && errno == ENOSYS) return ENOSYS;
  return 0;
}
""".}
  type SandboxChildC* = object
    ## Same layout as the C `js_sandbox` struct.
    network, userns: cint
    outer_uid, outer_gid: cuint
    nwritable: cint
    writable: ptr cstring
  proc jsSbNamespaces(c: pointer; step: ptr cint): cint {.importc: "js_sb_namespaces", nodecl.}
  proc jsSbForkPidNamespace(): cint {.importc: "js_sb_fork_pid_namespace", nodecl.}
  proc jsSbDropBounding(step: ptr cint): cint {.importc: "js_sb_drop_bounding", nodecl.}
  proc jsSbLockdown(step: ptr cint): cint {.importc: "js_sb_lockdown", nodecl.}
  proc jsSbProbe(): cint {.importc: "js_sb_probe", nodecl.}
else:
  type SandboxChildC* = object
    network, userns: cint
    outer_uid, outer_gid: cuint
    nwritable: cint
    writable: ptr cstring

const MaxSandboxWritablePaths* = 64
  ## Bound of the child's stack array of detached mounts (`JS_MAX_WRITABLE`).

proc sandboxSupported*(): bool =
  ## Whether this platform and kernel can provide every §13.8 property.
  when defined(linux):
    for ns in ["mnt", "pid", "ipc", "uts", "net"]:
      if not fileExists("/proc/self/ns/" & ns): return false
    jsSbProbe() == 0
  else:
    false

proc prepareSandbox*(config: SandboxConfig; userNamespace = geteuid() != 0;
                     sys = filesystemSystem()): PreparedSandbox =
  ## Parent-side half: validate everything that can be validated before
  ## `fork`. Raises `SandboxError` (`E_SANDBOX`) when the platform cannot
  ## provide the sandbox; callers MUST NOT fall back to running unsandboxed.
  when not defined(linux):
    fail("the sandbox requires Linux namespaces, seccomp and mount_setattr")
  else:
    result.writable = validateSandbox(config, sys)
    if result.writable.len > MaxSandboxWritablePaths:
      fail("too many writable paths")
    if userNamespace and fileExists("/proc/sys/user/max_user_namespaces"):
      try:
        if readFile("/proc/sys/user/max_user_namespaces").strip == "0":
          fail("unprivileged user namespaces are disabled")
      except IOError: discard
    if not sandboxSupported():
      fail("the kernel cannot provide every sandbox property")
    result.workingDirectory = normalizedPath(
      if config.workingDirectory.len == 0: "/" else: config.workingDirectory)
    result.network = config.network
    result.userNamespace = userNamespace
    result.outerUid = uint32(geteuid())
    result.outerGid = uint32(getegid())

type SandboxChildPlan* = object
  ## Memory the child-side C code reads. Build it before `fork` and keep it
  ## alive until the child has executed; the child never allocates.
  c*: SandboxChildC
  paths: seq[string]
  pointers: seq[cstring]

proc childPlan*(prepared: PreparedSandbox): ref SandboxChildPlan =
  new(result)
  result.paths = prepared.writable
  result.pointers = newSeq[cstring](result.paths.len + 1)
  for i in 0 ..< result.paths.len: result.pointers[i] = result.paths[i].cstring
  result.c.network = cint(ord(prepared.network))
  result.c.userns = cint(ord(prepared.userNamespace))
  result.c.outer_uid = cuint(prepared.outerUid)
  result.c.outer_gid = cuint(prepared.outerGid)
  result.c.nwritable = cint(result.paths.len)
  result.c.writable = addr result.pointers[0]

# These run in the child between fork and execve. They return 0 or an errno
# and set `step` to the failing `SandboxStep`.

proc sandboxChildNamespaces*(plan: ptr SandboxChildPlan; step: var cint): cint =
  when defined(linux):
    var raw: cint
    result = jsSbNamespaces(addr plan.c, addr raw)
    step = if result == 0: cint(ord(sbNone)) else: raw
  else:
    step = cint(ord(sbUnavailable)); result = ENOSYS

proc sandboxChildForkPidNamespace*(step: var cint): cint =
  when defined(linux):
    result = jsSbForkPidNamespace()
    step = if result == 0: cint(ord(sbNone)) else: cint(ord(sbPidNamespace))
  else:
    step = cint(ord(sbUnavailable)); result = ENOSYS

proc sandboxChildDropBounding*(step: var cint): cint =
  when defined(linux):
    var raw: cint
    result = jsSbDropBounding(addr raw)
    step = if result == 0: cint(ord(sbNone)) else: raw
  else:
    step = cint(ord(sbUnavailable)); result = ENOSYS

proc sandboxChildLockdown*(step: var cint): cint =
  when defined(linux):
    var raw: cint
    result = jsSbLockdown(addr raw)
    step = if result == 0: cint(ord(sbNone)) else: raw
  else:
    step = cint(ord(sbUnavailable)); result = ENOSYS

proc describeStep*(step: int): string =
  if step >= ord(low(SandboxStep)) and step <= ord(high(SandboxStep)):
    case SandboxStep(step)
    of sbNone: "sandbox"
    of sbUnshare: "unshare namespaces"
    of sbSetgroups: "deny setgroups in user namespace"
    of sbUidMap: "write uid_map"
    of sbGidMap: "write gid_map"
    of sbPrivate: "make mounts private"
    of sbCapture: "clone writable path"
    of sbReadOnly: "make root read-only"
    of sbTmp: "mount private /tmp"
    of sbAttach: "attach writable path"
    of sbLoopback: "bring loopback up"
    of sbPidNamespace: "enter PID namespace"
    of sbBounding: "drop bounding set"
    of sbCapabilities: "clear capabilities"
    of sbAmbient: "clear ambient capabilities"
    of sbNoNewPrivs: "set no_new_privs"
    of sbSeccomp: "install seccomp filter"
    of sbUnavailable: "sandbox unavailable"
  else: "sandbox step " & $step
