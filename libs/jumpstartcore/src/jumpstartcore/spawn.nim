## fork/exec process construction for core processes (§15.4).
##
## Every child gets: stdin from /dev/null; stdout and stderr on pipes; fds 3
## and 4 for the exec protocol when requested; no other descriptors (see the
## script exception below); a new session and process group; membership of
## the given cgroup before it can run any code of its own (§15.1 rule 8); the
## closed environment built by `environment.nim` (§7.5); default signal
## dispositions and an empty signal mask; and, when requested, a credential
## change, the §13.8 sandbox, and child-subreaper status (§15.2).
##
## Native serviceHandler units may select other standard descriptors
## (`ProcessSpec.nullStdio`, `ProcessSpec.inheritStdio`) and stay in the
## caller's session (`keepSession`); every other rule above still applies.
##
## A core's own helper process (not a protocol child) may instead be given
## descriptors the core already holds: `ProcessSpec.explicitStdio` makes three
## of them the child's 0, 1 and 2, and `ProcessSpec.passFds` places further
## descriptors at fixed numbers. Exactly those descriptors (plus 0-2, the
## protocol descriptors 3 and 4 when `protocol` is set, and descriptor 5 when
## a script is executed through a verified descriptor) survive `execve`;
## everything else is closed (§15.4).
##
## Setup failures in the child are reported through a close-on-exec status
## pipe as `(stage, errno)`; the child then exits with status 126 without
## executing anything, and `spawn` raises `SpawnError` with the §18 code for
## that stage (`E_SANDBOX`, `E_PERMISSION`, `E_CGROUP`, ...).
##
## Executables may be executed through a verified descriptor (§8.3, §24):
## `openVerifiedExecutable` opens with `O_NOFOLLOW`, re-checks owner, mode, and
## file type with `fstat`, and the child runs it with `execveat(fd, "",
## AT_EMPTY_PATH)` (falling back to `fexecve`). Interpreter scripts (`#!`) can
## only be executed through a descriptor that stays open across `execve`
## (the kernel hands the interpreter `/dev/fd/N`, or `/proc/self/fd/5` is
## executed when /dev has no `fd` symlink), so for scripts descriptor 5
## is left open in the new program; this is the only exception to "no other
## open descriptors". macOS has neither `execveat` nor `fexecve`: there the
## child re-checks that the path still names the verified file (same device
## and inode) and executes the path. That leaves a window between the check
## and `execve` which only Linux can close.
import std/[algorithm, options, os, sequtils, strutils, tables]
import posix
import ./[errors, reaper, sandbox]
import ./environment as coreenv
export coreenv.EnvPair, coreenv.buildSystemEnvironment, coreenv.SystemPath,
  coreenv.UserPath

var
  O_NOFOLLOW {.importc, header: "<fcntl.h>".}: cint
  O_DIRECTORY {.importc, header: "<fcntl.h>".}: cint

proc childExit(status: cint) {.importc: "_exit", header: "<unistd.h>", noreturn.}
proc setgroups(size: csize_t, groups: ptr Gid): cint
  {.importc, header: "<grp.h>".}

when defined(linux):
  {.emit: """
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <sys/syscall.h>
#include <unistd.h>
#ifndef AT_EMPTY_PATH
#define AT_EMPTY_PATH 0x1000
#endif
static int js_spawn_execfd(int fd, int script, char *const argv[], char *const envp[]) {
  /* A script's interpreter is handed "/dev/fd/N" by the kernel. A /dev without
   * that symlink (a bare devtmpfs before udev) cannot open it, so such a
   * script is executed by the always-present /proc/self/fd/N instead: the
   * same descriptor, hence the same verified file. */
  if (script) {
    char link[32];
    snprintf(link, sizeof link, "/dev/fd/%d", fd);
    if (access(link, F_OK) != 0) {
      snprintf(link, sizeof link, "/proc/self/fd/%d", fd);
      execve(link, argv, envp);
      return errno;
    }
  }
#ifdef SYS_execveat
  syscall(SYS_execveat, fd, "", argv, envp, AT_EMPTY_PATH);
  if (errno != ENOSYS) return errno;
#endif
  fexecve(fd, argv, envp);
  return errno;
}
static void js_spawn_close_from(int lowest) {
#ifdef SYS_close_range
  if (syscall(SYS_close_range, (unsigned)lowest, ~0U, 0) == 0) return;
#endif
  long max = sysconf(_SC_OPEN_MAX);
  if (max < 0 || max > 65536) max = 65536;
  for (int fd = lowest; fd < max; fd++) close(fd);
}
static void js_spawn_close_span(unsigned lo, unsigned hi) {
  /* closes lo..hi inclusive; hi == ~0U means "to the end" */
#ifdef SYS_close_range
  if (syscall(SYS_close_range, lo, hi, 0) == 0) return;
#endif
  long max = sysconf(_SC_OPEN_MAX);
  if (max < 0 || max > 65536) max = 65536;
  for (unsigned fd = lo; fd <= hi && fd < (unsigned)max; fd++) close(fd);
}
static void js_spawn_close_except(int lowest, const int *keep, int n) {
  /* keep: ascending, distinct, each >= lowest */
  unsigned next = (unsigned)lowest;
  for (int i = 0; i < n; i++) {
    if ((unsigned)keep[i] > next) js_spawn_close_span(next, (unsigned)keep[i] - 1);
    next = (unsigned)keep[i] + 1;
  }
  js_spawn_close_span(next, ~0U);
}
""".}
else:
  {.emit: """
#include <errno.h>
#include <signal.h>
#include <sys/stat.h>
#include <unistd.h>
static int js_spawn_execfd(int fd, const char *path, char *const argv[], char *const envp[]) {
  struct stat a, b;
  if (fstat(fd, &a) < 0) return errno;
  if (stat(path, &b) < 0) return errno;
  if (a.st_dev != b.st_dev || a.st_ino != b.st_ino) return ESTALE;
  execve(path, argv, envp);
  return errno;
}
static void js_spawn_close_from(int lowest) {
  long max = sysconf(_SC_OPEN_MAX);
  if (max < 0 || max > 65536) max = 65536;
  for (int fd = lowest; fd < max; fd++) close(fd);
}
static void js_spawn_close_except(int lowest, const int *keep, int n) {
  /* keep: ascending, distinct, each >= lowest */
  long max = sysconf(_SC_OPEN_MAX);
  if (max < 0 || max > 65536) max = 65536;
  int k = 0;
  for (int fd = lowest; fd < max; fd++) {
    if (k < n && keep[k] == fd) { k++; continue; }
    close(fd);
  }
}
""".}

{.emit: """
static void js_spawn_reset_signals(void) {
  for (int s = 1; s < NSIG; s++) {
    if (s == SIGKILL || s == SIGSTOP) continue;
    signal(s, SIG_DFL);
  }
  sigset_t none; sigemptyset(&none);
  sigprocmask(SIG_SETMASK, &none, NULL);
}
""".}

when defined(linux):
  proc jsExecFd(fd: cint; script: cint; argv, envp: cstringArray): cint {.importc: "js_spawn_execfd", nodecl.}
else:
  proc jsExecFdPath(fd: cint; path: cstring; argv, envp: cstringArray): cint
    {.importc: "js_spawn_execfd", nodecl.}
proc jsCloseFrom(lowest: cint) {.importc: "js_spawn_close_from", nodecl.}
proc jsCloseExcept(lowest: cint; keep: ptr cint; count: cint)
  {.importc: "js_spawn_close_except", nodecl.}
proc jsResetSignals() {.importc: "js_spawn_reset_signals", nodecl.}

const
  ExecutableFdSlot = 5.cint   ## descriptor holding the verified executable
  FirstFreeFd = 7.cint        ## parent-side temporaries are moved here or above

  MaxPassedFd* = 1023.cint
    ## Highest descriptor number `ProcessSpec.passFds` may name.

type
  PassedFd* = tuple[source, target: cint]
    ## One inherited descriptor: the caller's `source` becomes `target` in the
    ## child, with `FD_CLOEXEC` cleared.
  SpawnStage* = enum
    ## Child setup stage reported through the status pipe.
    ssNone, ssDescriptors, ssSubreaper, ssSandbox, ssIdentity,
    ssWorkingDirectory, ssExec
  SpawnError* = object of CoreError
    stage*: SpawnStage
    osError*: OSErrorCode
    sandboxStep*: int
  ProcessIdentity* = object
    ## Resolved credentials for the `user` option (§13.1, §15.2).
    user*: string
    uid*: Uid
    gid*: Gid
    groups*: seq[Gid]
  VerifiedExecutable* = object
    fd*: cint
    path*: string
    uid*: Uid
    device*: Dev
    inode*: Ino
    script*: bool
  ProcessSpec* = object
    executable*: string           ## argv[0] and, without a descriptor, the path executed
    executableFd*: Option[cint]   ## verified descriptor to execute (§8.3); not consumed
    arguments*: seq[string]
    environment*: seq[EnvPair]    ## complete environment; nothing is inherited
    workingDirectory*: string
    uid*: Uid
    gid*: Gid
    setIdentity*: bool
    supplementaryGroups*: seq[Gid]
    protocol*: bool               ## fds 3 and 4 (§17.1)
    supervisorSubreaper*: bool    ## PR_SET_CHILD_SUBREAPER before execve (§15.2)
    cgroupProcs*: string          ## `cgroup.procs` of the target cgroup, joined before execve
    sandbox*: Option[PreparedSandbox]
    keepSession*: bool
      ## Stay in the caller's session and process group instead of `setsid`.
      ## Only for programs a Kongue runner starts with `spawn`/`exec`: they
      ## belong to the runner's operation, so §13.7 cancellation of the
      ## runner's process group must reach them, and for serviceHandler's
      ## `terminal: true` services, which stay in PID 1's session and process
      ## group (jumpstart_dec(5)). Core processes started by Jumpstart always
      ## get a new session (§15.4).
    nullStdio*: bool
      ## stdin, stdout, and stderr all on /dev/null; no pipes are created, so
      ## `SpawnedProcess.stdoutFd`/`stderrFd` are -1 and nothing needs to be
      ## drained. Used for ordinary native units, whose output was always
      ## discarded.
    inheritStdio*: bool
      ## stdin, stdout, and stderr are the caller's own descriptors 0-2 (the
      ## daemon's console); no pipes are created (`stdoutFd`/`stderrFd` are
      ## -1). Used with `keepSession` for `terminal: true` native services.
      ## Mutually exclusive with `nullStdio`.
    explicitStdio*: Option[array[3, cint]]
      ## Descriptors that become 0, 1, and 2 in the child (`dup2`). No pipes
      ## are created, so `SpawnedProcess.stdoutFd`/`stderrFd` are -1. Mutually
      ## exclusive with `nullStdio` and `inheritStdio`. The descriptors are
      ## the caller's: they are neither consumed nor closed, and may be equal
      ## to each other or to 0-2 of the caller (a swap such as `[1, 0, 2]` is
      ## fine, because every source is copied first).
    passFds*: seq[PassedFd]
      ## Further descriptors the child inherits at fixed numbers, each with
      ## `FD_CLOEXEC` cleared; every other descriptor is closed. Rules:
      ## - a `target` is at most `MaxPassedFd` (1023) and not 0-2 (those are
      ##   the standard descriptors);
      ## - targets 3 and 4 are the exec protocol descriptors, so they are
      ##   available only when `protocol` is false (the process is a core's
      ##   own helper and not a protocol child; protocol descriptors exist
      ##   only when `protocol` is requested). Every `target` of 5 or more is
      ##   always available, except that 5 is the interpreter descriptor of a
      ##   script run through `executableFd` and is refused then (a binary
      ##   runs from a private copy, so 5 is free). The spawn layer's own
      ##   status descriptor is a private copy on no target;
      ## - targets are distinct; a `source` may equal another entry's `target`
      ##   or the caller's 0-2 (each source is first copied to a number that is
      ##   no target, before any `dup2`); several entries may share one `source`;
      ## - an invalid `source` or `target` is a `ValueError`; the sources are
      ##   not consumed.
  SpawnedProcess* = object
    pid*, processGroup*: Pid
    stdoutFd*, stderrFd*: cint
    protocolWriteFd*: cint
    protocolReadFd*: cint

proc closeFd*(fd: cint) {.inline.} =
  if fd >= 0: discard close(fd)

proc spawnFail(code: CoreErrorCode; message: string; stage = ssNone;
               err = OSErrorCode(0); sandboxStep = 0) {.noreturn.} =
  var e = newException(SpawnError, message)
  e.code = code
  e.message = message
  e.stage = stage
  e.osError = err
  e.sandboxStep = sandboxStep
  raise e

# ---------------------------------------------------------------------------
# Identity

proc getgrouplist(user: cstring; group: Gid; groups: ptr Gid; ngroups: ptr cint): cint
  {.importc, header: "<grp.h>".}

proc resolveIdentity*(user: string): ProcessIdentity =
  ## Look up `user` in the password database and compute its supplementary
  ## groups, as `initgroups` would. Done in the parent because the lookup is
  ## not async-signal-safe. A missing account is `E_PERMISSION` (§13.1: the
  ## account MUST exist at dispatch time).
  if user.len == 0 or '\0' in user: spawnFail(ecPermission, "invalid account name")
  var pw: Passwd
  var found: ptr Passwd
  var buffer = newString(16384)
  if getpwnam_r(user.cstring, addr pw, buffer.cstring, buffer.len, addr found) != 0 or
      found.isNil:
    spawnFail(ecPermission, "account does not exist: " & user)
  result = ProcessIdentity(user: user, uid: pw.pw_uid, gid: pw.pw_gid)
  var count: cint = 64
  while true:
    var groups = newSeq[Gid](count)
    var n = count
    let rc = getgrouplist(user.cstring, pw.pw_gid, addr groups[0], addr n)
    if rc >= 0:
      groups.setLen(n)
      result.groups = groups
      break
    if count >= 65536: spawnFail(ecPermission, "too many groups for " & user)
    count = max(n, count * 2)

proc applyIdentity*(spec: var ProcessSpec; identity: ProcessIdentity) =
  spec.setIdentity = true
  spec.uid = identity.uid
  spec.gid = identity.gid
  spec.supplementaryGroups = identity.groups

proc userIdentityFor*(uid: Uid): coreenv.UserIdentity =
  ## Password-database fields for the user-mode base environment (§7.5).
  var pw: Passwd
  var found: ptr Passwd
  var buffer = newString(16384)
  if getpwuid_r(uid, addr pw, buffer.cstring, buffer.len, addr found) != 0 or
      found.isNil:
    spawnFail(ecPermission, "no password database entry for uid " & $uid)
  coreenv.UserIdentity(uid: int(uid), home: $pw.pw_dir, user: $pw.pw_name,
    logname: $pw.pw_name, shell: $pw.pw_shell)

# ---------------------------------------------------------------------------
# Verified executables (§8.3, §24)

proc pread(fd: cint; buf: pointer; count: int; offset: Off): int
  {.importc, header: "<unistd.h>".}

proc isScript(fd: cint): bool =
  var magic: array[2, char]
  pread(fd, addr magic[0], 2, 0) == 2 and magic[0] == '#' and magic[1] == '!'

proc checkVerified(fd: cint; path: string; trustedUid: Uid): VerifiedExecutable =
  var st: Stat
  if fstat(fd, st) != 0: spawnFail(ecPermission, "cannot fstat executable: " & path)
  if not S_ISREG(st.st_mode): spawnFail(ecPermission, "executable is not a regular file: " & path)
  if st.st_uid != trustedUid and st.st_uid != Uid(0):
    spawnFail(ecPermission, "executable is not owned by the trusted owner: " & path)
  if (int(st.st_mode) and 0o022) != 0:
    spawnFail(ecPermission, "executable is writable by group or other: " & path)
  if (int(st.st_mode) and 0o100) == 0:
    spawnFail(ecPermission, "executable is not executable by its owner: " & path)
  VerifiedExecutable(fd: fd, path: path, uid: st.st_uid, device: st.st_dev,
    inode: st.st_ino, script: isScript(fd))

proc openVerifiedExecutable*(path: string; trustedUid: Uid;
                             beneath = ""): VerifiedExecutable =
  ## Open `path` without following symlinks and re-check it on the open
  ## descriptor: regular file, owned by `trustedUid` or root, not writable by
  ## group or other, executable by its owner. With `beneath` (for example the
  ## core directory), every component below it is opened with `O_NOFOLLOW`
  ## too, so a symlink anywhere in the extension tree is rejected. The result
  ## owns a close-on-exec descriptor. Failure is `E_PERMISSION` (§8.3).
  if path.len == 0 or not path.isAbsolute or '\0' in path:
    spawnFail(ecPermission, "executable path must be absolute")
  var fd: cint = -1
  if beneath.len == 0:
    fd = posix.open(path.cstring, O_RDONLY or O_NOFOLLOW or O_CLOEXEC)
    if fd < 0: spawnFail(ecPermission, "cannot open executable " & path & ": " &
      osErrorMsg(osLastError()), err = osLastError())
  else:
    let base = beneath.strip(leading = false, chars = {'/'})
    if not path.startsWith(base & "/"):
      spawnFail(ecPermission, "executable escapes " & beneath & ": " & path)
    var dirFd = posix.open((if base.len == 0: "/" else: base).cstring,
      O_RDONLY or O_DIRECTORY or O_CLOEXEC)
    if dirFd < 0: spawnFail(ecPermission, "cannot open " & beneath, err = osLastError())
    let parts = path[base.len + 1 .. ^1].split('/')
    for i, part in parts:
      if part.len == 0 or part == "." or part == "..":
        closeFd(dirFd)
        spawnFail(ecPermission, "invalid executable path component: " & path)
      let last = i == parts.high
      let flags = O_RDONLY or O_NOFOLLOW or O_CLOEXEC or (if last: 0.cint else: O_DIRECTORY)
      proc openat(dirfd: cint; path: cstring; flags: cint): cint
        {.importc, header: "<fcntl.h>", varargs.}
      let next = openat(dirFd, part.cstring, flags)
      let err = osLastError()
      closeFd(dirFd)
      if next < 0:
        spawnFail(ecPermission, "cannot open executable " & path & ": " & osErrorMsg(err),
          err = err)
      dirFd = next
    fd = dirFd
  try:
    result = checkVerified(fd, path, trustedUid)
  except CatchableError:
    closeFd(fd)
    raise

proc close*(executable: var VerifiedExecutable) =
  closeFd(executable.fd)
  executable.fd = -1

# ---------------------------------------------------------------------------
# Descriptor helpers

proc setCloseOnExec(fd: cint) =
  if fcntl(fd, F_SETFD, FD_CLOEXEC) < 0: raiseOSError(osLastError())

proc moveAboveReserved(fd: cint): cint =
  ## Parent temporaries live at FirstFreeFd or above so that the child's
  ## dup2 into 0..6 can never clobber a source descriptor.
  if fd >= FirstFreeFd: return fd
  result = fcntl(fd, F_DUPFD, FirstFreeFd)
  if result < 0: raiseOSError(osLastError())
  closeFd(fd)

proc makePipe(): array[2, cint] =
  var raw: array[2, cint]
  if pipe(raw) != 0: raiseOSError(osLastError())
  result = [-1.cint, -1.cint]
  try:
    result[0] = moveAboveReserved(raw[0])
    raw[0] = -1
    result[1] = moveAboveReserved(raw[1])
    raw[1] = -1
    setCloseOnExec(result[0]); setCloseOnExec(result[1])
  except:
    closeFd(raw[0]); closeFd(raw[1])
    closeFd(result[0]); closeFd(result[1])
    raise

proc writeAll(fd: cint, data: pointer, size: int): bool =
  var done = 0
  while done < size:
    let n = write(fd, cast[pointer](cast[uint](data) + uint(done)), size - done)
    if n > 0: done += int(n)
    elif n < 0 and osLastError() == OSErrorCode(EINTR): discard
    else: return false
  true

proc readFull(fd: cint; data: pointer; size: int): int =
  ## Read until `size` bytes or EOF; returns the byte count.
  while result < size:
    let n = read(fd, cast[pointer](cast[uint](data) + uint(result)), size - result)
    if n > 0: result += int(n)
    elif n < 0 and osLastError() == OSErrorCode(EINTR): continue
    else: break

proc addToCgroup(path: string, pid: Pid) =
  if path.len == 0: return
  let fd = posix.open(path.cstring, O_WRONLY or O_CLOEXEC)
  if fd < 0: spawnFail(ecCgroup, "cannot open " & path & ": " & osErrorMsg(osLastError()),
    err = osLastError())
  defer: closeFd(fd)
  let value = $pid & "\n"
  if not writeAll(fd, unsafeAddr value[0], value.len):
    spawnFail(ecCgroup, "cannot join cgroup " & path & ": " & osErrorMsg(osLastError()),
      err = osLastError())

proc codeFor(stage: SpawnStage; err: cint): CoreErrorCode =
  case stage
  of ssSandbox: ecSandbox
  of ssIdentity: ecPermission
  of ssExec:
    if err == EACCES or err == EPERM or err == ESTALE: ecPermission else: ecBackend
  else: ecIo

proc stageName(stage: SpawnStage): string =
  case stage
  of ssNone: "setup"
  of ssDescriptors: "descriptor setup"
  of ssSubreaper: "child subreaper"
  of ssSandbox: "sandbox"
  of ssIdentity: "credential change"
  of ssWorkingDirectory: "working directory"
  of ssExec: "execve"

proc spawn*(spec: ProcessSpec, reaper: Reaper, owner = "",
            callback: ChildCallback = nil): SpawnedProcess =
  ## Start one process. A gate keeps the child from running anything until it
  ## is in its cgroup and registered with the central reaper (§15.3).
  if spec.executable.len == 0 or '\0' in spec.executable:
    raise newException(ValueError, "invalid executable")
  if spec.workingDirectory.len == 0 or '\0' in spec.workingDirectory or
      not spec.workingDirectory.isAbsolute:
    raise newException(ValueError, "invalid working directory")
  if reaper.isNil: raise newException(ValueError, "a central reaper is required")
  if spec.nullStdio and spec.inheritStdio:
    raise newException(ValueError, "nullStdio and inheritStdio are exclusive")
  if spec.explicitStdio.isSome and (spec.nullStdio or spec.inheritStdio):
    raise newException(ValueError, "explicitStdio excludes nullStdio and inheritStdio")
  let pipedStdio = not (spec.nullStdio or spec.inheritStdio or spec.explicitStdio.isSome)
  var passedTargets: seq[cint]
  for entry in spec.passFds:
    if entry.target < 3 or entry.target > MaxPassedFd:
      raise newException(ValueError, "invalid passFds target " & $entry.target)
    if (entry.target == 3 or entry.target == 4) and spec.protocol:
      raise newException(ValueError, "passFds target " & $entry.target &
        " is a protocol descriptor")
    if entry.target in passedTargets:
      raise newException(ValueError, "duplicate passFds target " & $entry.target)
    passedTargets.add entry.target
    if entry.source < 0 or fcntl(entry.source, F_GETFD) < 0:
      raise newException(ValueError, "invalid passFds source " & $entry.source)
  if spec.explicitStdio.isSome:
    for source in spec.explicitStdio.get:
      if source < 0 or fcntl(source, F_GETFD) < 0:
        raise newException(ValueError, "invalid explicitStdio descriptor " & $source)
  # Close-on-exec set of the child's descriptors at or above FirstFreeFd.
  var keepSet: seq[cint]
  for target in passedTargets:
    if target >= FirstFreeFd: keepSet.add target
  for arg in spec.arguments:
    if '\0' in arg: raise newException(ValueError, "NUL in argument")
  # envp never carries a key twice (§7.5): when a caller appended a later
  # layer, the later value wins.
  var envIndex = initTable[string, int]()
  var envStore: seq[string]
  for (key, value) in spec.environment:
    if key.len == 0 or '=' in key or '\0' in key or '\0' in value:
      raise newException(ValueError, "invalid environment")
    if envIndex.hasKey(key): envStore[envIndex[key]] = key & "=" & value
    else:
      envIndex[key] = envStore.len
      envStore.add(key & "=" & value)
  if spec.sandbox.isSome and spec.sandbox.get.workingDirectory != spec.workingDirectory:
    raise newException(ValueError, "sandbox and process working directories differ")

  var argvStore = @[spec.executable] & spec.arguments
  var argv = newSeq[cstring](argvStore.len + 1)
  var envp = newSeq[cstring](envStore.len + 1)
  for i in 0 ..< argvStore.len: argv[i] = argvStore[i].cstring
  for i in 0 ..< envStore.len: envp[i] = envStore[i].cstring
  let workingDirectory = spec.workingDirectory
  let executablePath = spec.executable
  let groupCount = spec.supplementaryGroups.len
  let groups = if groupCount == 0: nil else: unsafeAddr spec.supplementaryGroups[0]

  var sandboxPlan: ref SandboxChildPlan
  if spec.sandbox.isSome: sandboxPlan = childPlan(spec.sandbox.get)

  var execFd: cint = -1
  var script = false
  var outPipe, errPipe, gate, ready, status: array[2, cint]
  var toChild = [-1.cint, -1.cint]; var fromChild = [-1.cint, -1.cint]
  var devNull: cint = -1
  var stdioCopies = [-1.cint, -1.cint, -1.cint]
  var passCopies = newSeq[cint](spec.passFds.len)
  for i in 0 ..< passCopies.len: passCopies[i] = -1
  for p in [addr outPipe, addr errPipe, addr gate, addr ready, addr status]: p[] = [-1.cint, -1.cint]
  var rejected: seq[cint]   ## copies that landed on a target number, kept open meanwhile
  proc cleanupParent() =
    for fd in [execFd, devNull, outPipe[0], outPipe[1], errPipe[0], errPipe[1],
               gate[0], gate[1], ready[0], ready[1], status[0], status[1],
               toChild[0], toChild[1], fromChild[0], fromChild[1]].toSeq & @stdioCopies & passCopies &
               rejected:
      closeFd(fd)
  proc copyAvoidingTargets(source: cint): cint =
    ## A close-on-exec copy at FirstFreeFd or above whose number is not any
    ## passFds target, so that no dup2 of the child can clobber a copy that
    ## still has to be used (the numbers below stay small, within any limit).
    var base = FirstFreeFd
    while true:
      let fd = fcntl(source, F_DUPFD, base)
      if fd < 0: raiseOSError(osLastError())
      if fd in passedTargets:
        rejected.add fd
        base = fd + 1
      else:
        setCloseOnExec(fd)
        return fd
  try:
    if spec.executableFd.isSome:
      var st: Stat
      let source = spec.executableFd.get
      if fstat(source, st) != 0 or not S_ISREG(st.st_mode):
        spawnFail(ecPermission, "executable descriptor is not a regular file")
      script = isScript(source)
      execFd = copyAvoidingTargets(source)
      if script and 5 in passedTargets:
        spawnFail(ecPermission, "passFds target 5 is the interpreter descriptor of a script")
    if pipedStdio:
      outPipe = makePipe(); errPipe = makePipe()
    gate = makePipe(); ready = makePipe(); status = makePipe()
    if spec.protocol:
      toChild = makePipe(); fromChild = makePipe()
    if spec.explicitStdio.isSome:
      for i in 0 .. 2: stdioCopies[i] = copyAvoidingTargets(spec.explicitStdio.get[i])
    for i, entry in spec.passFds: passCopies[i] = copyAvoidingTargets(entry.source)
    # The child reports setup failures through this close-on-exec descriptor.
    # It sits on no target number and survives the close-above step below.
    let rawStatus = status[1]
    status[1] = copyAvoidingTargets(rawStatus)
    closeFd(rawStatus)
    for fd in rejected: closeFd(fd)
    rejected.setLen(0)
    if not (spec.inheritStdio or spec.explicitStdio.isSome):
      let rawNull = posix.open("/dev/null",
        (if spec.nullStdio: O_RDWR else: O_RDONLY) or O_CLOEXEC)
      if rawNull < 0: raiseOSError(osLastError())
      devNull = moveAboveReserved(rawNull)
  except:
    cleanupParent()
    raise

  let statusFd = status[1]
  let execSlot = if script: ExecutableFdSlot else: execFd
  keepSet.add statusFd
  if execFd >= 0 and not script: keepSet.add execFd
  keepSet.sort()
  let keepPointer: ptr cint = addr keepSet[0]
  let pid = fork()
  if pid < 0:
    let err = osLastError()
    cleanupParent()
    raiseOSError(err)
  if pid == 0:
    # Child: only async-signal-safe calls on memory prepared above.
    closeFd(gate[1]); closeFd(ready[0]); closeFd(outPipe[0]); closeFd(errPipe[0])
    closeFd(status[0])
    if spec.protocol: closeFd(toChild[1]); closeFd(fromChild[0])
    # Establish the process group before the parent can return; the gate still
    # prevents exec until registration and cgroup placement.
    if not spec.keepSession and setsid() < 0: childExit(126)
    var readyToken = 'r'
    if not writeAll(ready[1], addr readyToken, 1): childExit(126)
    closeFd(ready[1])
    var token: char
    var gateRead: int
    while true:
      gateRead = int(read(gate[0], addr token, 1))
      if gateRead < 0 and osLastError() == OSErrorCode(EINTR): continue
      break
    if gateRead != 1 or token != 'x': childExit(126)

    var report: array[3, int32]
    template childFail(stage: SpawnStage; err: cint; step = 0.cint) =
      report[0] = int32(ord(stage)); report[1] = int32(err); report[2] = int32(step)
      discard writeAll(statusFd, addr report[0], sizeof(report))
      childExit(126)

    if spec.inheritStdio:
      # The caller's 0-2 stay; make sure they survive execve.
      for fd in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO]:
        discard fcntl(cint(fd), F_SETFD, 0)
    elif spec.explicitStdio.isSome:
      # dup2 clears FD_CLOEXEC on the new descriptor; the copies are on no
      # target number and untouched by these three calls.
      if dup2(stdioCopies[0], STDIN_FILENO) < 0 or dup2(stdioCopies[1], STDOUT_FILENO) < 0 or
         dup2(stdioCopies[2], STDERR_FILENO) < 0:
        childFail(ssDescriptors, cint(errno))
    elif spec.nullStdio:
      if dup2(devNull, STDIN_FILENO) < 0 or dup2(devNull, STDOUT_FILENO) < 0 or
         dup2(devNull, STDERR_FILENO) < 0:
        childFail(ssDescriptors, cint(errno))
    elif dup2(devNull, STDIN_FILENO) < 0 or dup2(outPipe[1], STDOUT_FILENO) < 0 or
       dup2(errPipe[1], STDERR_FILENO) < 0:
      childFail(ssDescriptors, cint(errno))
    if spec.protocol:
      if dup2(toChild[0], 3) < 0 or dup2(fromChild[1], 4) < 0:
        childFail(ssDescriptors, cint(errno))
      # §15.4: the process sets FD_CLOEXEC on 3 and 4 itself; across this
      # execve they must stay open.
      discard fcntl(3, F_SETFD, 0); discard fcntl(4, F_SETFD, 0)
    else:
      closeFd(3); closeFd(4)
    closeFd(6)
    closeFd(ExecutableFdSlot)
    if execFd >= 0:
      # A script's interpreter opens /dev/fd/5 after execve, so it must stay
      # open there; a binary is executed from its own close-on-exec copy,
      # which is on no passFds target, so 5 stays free for the caller.
      if script:
        if dup2(execFd, ExecutableFdSlot) < 0: childFail(ssDescriptors, cint(errno))
        discard fcntl(ExecutableFdSlot, F_SETFD, 0)
    # Inherited descriptors last: a target may equal the number of a parent
    # temporary (a pipe end) that no later step needs. The sources are copies
    # on no target number, so these dup2 calls cannot clobber each other.
    for i in 0 ..< spec.passFds.len:
      if dup2(passCopies[i], spec.passFds[i].target) < 0:
        childFail(ssDescriptors, cint(errno))
    jsCloseExcept(FirstFreeFd, keepPointer, cint(keepSet.len))

    when defined(linux):
      if spec.supervisorSubreaper:
        const PrSetChildSubreaper = 36.cint
        proc prctl(option: cint, arg2: culong): cint {.importc, header: "<sys/prctl.h>", varargs.}
        if prctl(PrSetChildSubreaper, 1.culong) != 0: childFail(ssSubreaper, cint(errno))
    else:
      if spec.supervisorSubreaper: childFail(ssSubreaper, ENOSYS)

    if not sandboxPlan.isNil:
      var step: cint
      var err = sandboxChildNamespaces(addr sandboxPlan[], step)
      if err != 0: childFail(ssSandbox, err, step)
      err = sandboxChildForkPidNamespace(step)
      if err != 0: childFail(ssSandbox, err, step)
      err = sandboxChildDropBounding(step)
      if err != 0: childFail(ssSandbox, err, step)

    if spec.setIdentity:
      if setgroups(csize_t(groupCount), groups) != 0: childFail(ssIdentity, cint(errno))
      if setgid(spec.gid) != 0: childFail(ssIdentity, cint(errno))
      if setuid(spec.uid) != 0: childFail(ssIdentity, cint(errno))

    if not sandboxPlan.isNil:
      var step: cint
      let err = sandboxChildLockdown(step)
      if err != 0: childFail(ssSandbox, err, step)

    if chdir(workingDirectory.cstring) != 0: childFail(ssWorkingDirectory, cint(errno))
    jsResetSignals()
    let argvp = cast[cstringArray](addr argv[0])
    let envpp = cast[cstringArray](addr envp[0])
    if execFd >= 0:
      when defined(linux):
        childFail(ssExec, jsExecFd(execSlot, cint(script), argvp, envpp))
      else:
        childFail(ssExec, jsExecFdPath(execSlot, executablePath.cstring, argvp, envpp))
    else:
      discard execve(executablePath.cstring, argvp, envpp)
      childFail(ssExec, cint(errno))

  # Parent.
  for fd in @[execFd, devNull, gate[0], ready[1], outPipe[1], errPipe[1], status[1]] &
      @stdioCopies & passCopies:
    closeFd(fd)
  stdioCopies = [-1.cint, -1.cint, -1.cint]
  for i in 0 ..< passCopies.len: passCopies[i] = -1
  execFd = -1; devNull = -1; gate[0] = -1; ready[1] = -1; outPipe[1] = -1
  errPipe[1] = -1; status[1] = -1
  if spec.protocol:
    closeFd(toChild[0]); closeFd(fromChild[1]); toChild[0] = -1; fromChild[1] = -1
  var registered = false
  try:
    var readyToken: char
    let readyRead = readFull(ready[0], addr readyToken, 1)
    closeFd(ready[0]); ready[0] = -1
    if readyRead != 1 or readyToken != 'r':
      raise newException(OSError, "child failed before process setup")
    addToCgroup(spec.cgroupProcs, pid)
    reaper.register(pid, owner, callback)
    registered = true
    var token = 'x'
    if not writeAll(gate[1], addr token, 1): raiseOSError(osLastError())
    closeFd(gate[1]); gate[1] = -1
    # EOF on the status pipe means execve succeeded (or, in the sandbox, that
    # every intermediate process dropped its copy and the program executed).
    var report: array[3, int32]
    let got = readFull(status[0], addr report[0], sizeof(report))
    closeFd(status[0]); status[0] = -1
    if got != 0:
      let stage = if got == sizeof(report) and report[0] >= int32(ord(low(SpawnStage))) and
                     report[0] <= int32(ord(high(SpawnStage))): SpawnStage(report[0])
                  else: ssNone
      let err = cint(report[1])
      var message = stageName(stage) & " failed"
      if stage == ssSandbox: message = "sandbox: " & describeStep(int(report[2])) & " failed"
      if err != 0: message.add ": " & osErrorMsg(OSErrorCode(err))
      spawnFail(codeFor(stage, err), message, stage, OSErrorCode(err), int(report[2]))
  except:
    # The child never executed the program. Leave its exit to the reaper,
    # which logs unregistered children (§15.3).
    if registered: discard reaper.unregister(pid)
    discard kill(pid, SIGKILL)
    cleanupParent()
    raise
  result = SpawnedProcess(pid: pid,
    processGroup: if spec.keepSession: getpgrp() else: pid, stdoutFd: outPipe[0],
    stderrFd: errPipe[0], protocolWriteFd: toChild[1], protocolReadFd: fromChild[0])
