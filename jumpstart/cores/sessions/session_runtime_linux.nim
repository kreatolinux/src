## Production Linux `SessionRuntimeOps` for the system daemon (§7.6 steps
## 4-5, §20.8 step 2).
##
## Start: /run/user (root, 0755); a dedicated tmpfs on /run/user/UID with
## `size=10%,mode=0700,uid=UID,gid=GID,nosuid,nodev` (a pre-existing
## /run/user/UID that is not such a mount fails with E_PERMISSION); the
## cgroup users/UID/ with its daemon/ leaf, delegated as §15.1 rule 4; then
## `jumpstart --user` spawned directly into users/UID/daemon/ with
## supplementary groups, GID and UID set, every capability dropped (bounding
## set, ambient, and the permitted/effective sets through the UID change),
## PR_SET_NO_NEW_PRIVS, the user-mode base environment (§7.5) and the home
## directory as working directory; finally a wait of up to 10 seconds for the
## user socket to accept connections.
##
## The readiness probe runs in a short-lived child that has dropped to the
## user's credentials before it connects, so the system daemon itself never
## opens anything the user controls, never follows the user's symlinks with
## root privileges, and reads nothing from the user daemon (§7.6, last
## paragraph).
##
## Stop is non-blocking: SIGTERM now, SIGKILL after 30 seconds from `tick`,
## then the cgroup kill/removal and the unmount (lazily if busy) of
## /run/user/UID and removal of the empty mount point. Nothing inside the
## user's runtime directory is ever walked or deleted.
import std/[os, strutils, tables]
import posix
import ../manifest/modes, ./[session_manager, sessions]
import jumpstartcore/[cgroups, environment, errors, reaper]

type
  SessionRuntimeLog* = proc(message: string) {.closure.}
  SessionExitHandler* = proc(account: AccountInfo; status: ChildStatus;
                             causedBySystem, socketInUse: bool) {.closure.}
    ## Delivered from `tick` for every user daemon exit that did not happen
    ## during `start`. The daemon forwards it to SessionModel.daemonExited.

  LinuxSessionConfig* = object
    jumpstartExecutable*: string ## absolute path of the jumpstart binary
    runUserRoot*: string         ## "/run/user" in production
    usersCgroupRoot*: string     ## ".../jumpstart/users"; "" without cgroup v2
    cgroupSystem*: CgroupSystem
    mountInfoPath*: string       ## "/proc/self/mountinfo"
    socketRelative*: string      ## user socket below home (§7.2)
    reaper*: Reaper
    now*: proc(): int64 {.closure.}       ## monotonic milliseconds
    pause*: proc(milliseconds: int) {.closure.}
    log*: SessionRuntimeLog
    onExit*: SessionExitHandler

  DaemonRecord = object
    account: AccountInfo
    pid: Pid
    running: bool
    starting: bool
    stopRequested: bool
    stopDeadline: int64
    killSent: bool
    exitPending: bool
    exitStatus: ChildStatus

  LinuxSessionRuntime* = ref object
    config*: LinuxSessionConfig
    daemons: Table[SessionUid, DaemonRecord]

const
  UserSocketWaitMs* = 10_000'i64     ## §7.6 step 4.5
  UserStopGraceMs* = 30_000'i64      ## §7.6 step 5
  UserKillReapMs* = 5_000'i64
  RunUserTmpfsOptions* = "size=10%,mode=0700"

proc defaultLinuxSessionConfig*(jumpstartExecutable: string; reaper: Reaper;
                                usersCgroupRoot: string): LinuxSessionConfig =
  LinuxSessionConfig(jumpstartExecutable: jumpstartExecutable,
    runUserRoot: "/run/user", usersCgroupRoot: usersCgroupRoot,
    cgroupSystem: defaultCgroupSystem(), mountInfoPath: "/proc/self/mountinfo",
    socketRelative: ".local/share/jumpstart/jumpstart.sock", reaper: reaper)

proc tmpfsData*(uid, gid: uint32): string =
  RunUserTmpfsOptions & ",uid=" & $uid & ",gid=" & $gid

proc say(runtime: LinuxSessionRuntime; message: string) =
  if not runtime.config.log.isNil:
    try: runtime.config.log(message)
    except CatchableError: discard

proc runtimeDirFor*(runtime: LinuxSessionRuntime; uid: SessionUid): string =
  runtime.config.runUserRoot / $uid

proc userCgroup*(runtime: LinuxSessionRuntime; uid: SessionUid): string =
  ## users/UID/ for shutdown_linux's userCgroup hook ("" without cgroups).
  if runtime.config.usersCgroupRoot.len == 0: ""
  else: userCgroups(runtime.config.usersCgroupRoot, int(uid)).user

proc userPid*(runtime: LinuxSessionRuntime; uid: SessionUid): int =
  ## PID of the running user daemon or 0, for shutdown_linux's userPid hook.
  if runtime.daemons.hasKey(uid) and runtime.daemons[uid].running:
    int(runtime.daemons[uid].pid)
  else: 0

proc runningUids*(runtime: LinuxSessionRuntime): seq[int] =
  for uid, record in runtime.daemons:
    if record.running: result.add int(uid)

proc mountEntry(mountInfo, path: string): tuple[found: bool; fsType, options: string] =
  ## Topmost mount exactly at path.
  for line in mountInfo.splitLines:
    let halves = line.split(" - ", maxsplit = 1)
    if halves.len != 2: continue
    let left = halves[0].splitWhitespace
    let right = halves[1].splitWhitespace
    if left.len < 6 or right.len < 1: continue
    var point = left[4]
    point = point.replace("\\040", " ").replace("\\011", "\t").replace("\\012", "\n").replace("\\134", "\\")
    if point == path:
      result = (true, right[0], left[5])

proc isJumpstartRuntimeMount*(mountInfo, path: string; uid: uint32): bool =
  ## "such a mount" (§7.6 step 4.2): a tmpfs exactly at path with nosuid and
  ## nodev, whose root is a 0700 directory owned by the user.
  let entry = mountEntry(mountInfo, path)
  if not entry.found or entry.fsType != "tmpfs": return false
  let options = entry.options.split(',')
  if "nosuid" notin options or "nodev" notin options: return false
  var st: Stat
  lstat(path.cstring, st) == 0 and S_ISDIR(st.st_mode) and
    st.st_uid == Uid(uid) and (st.st_mode and Mode(0o777)) == Mode(0o700)

when defined(linux):
  {.emit: """
#define _GNU_SOURCE
#include <errno.h>
#include <grp.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/mount.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/un.h>
#ifndef PR_CAP_AMBIENT
#define PR_CAP_AMBIENT 47
#endif
#ifndef PR_CAP_AMBIENT_CLEAR_ALL
#define PR_CAP_AMBIENT_CLEAR_ALL 4
#endif
static int js_drop_identity(unsigned gid, unsigned uid, const gid_t *groups, int ngroups) {
  int cap;
  if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) return -1;
  for (cap = 0; cap < 64; cap++) {
    if (prctl(PR_CAPBSET_DROP, cap, 0, 0, 0) != 0) {
      if (errno == EINVAL) break;
      return -1;
    }
  }
  if (setgroups((size_t)ngroups, groups) != 0) return -1;
  if (setresgid(gid, gid, gid) != 0) return -1;
  if (setresuid(uid, uid, uid) != 0) return -1;
  (void)prctl(PR_CAP_AMBIENT, PR_CAP_AMBIENT_CLEAR_ALL, 0, 0, 0);
  if (uid != 0 && (setuid(0) == 0 || seteuid(0) == 0)) return -1;
  return 0;
}
static int js_probe_unix(const char *path, int timeout_ms) {
  struct sockaddr_un a; struct timespec start, now, delay = {0, 50000000};
  memset(&a, 0, sizeof a); a.sun_family = AF_UNIX;
  if (strlen(path) >= sizeof a.sun_path) return 2;
  strcpy(a.sun_path, path);
  clock_gettime(CLOCK_MONOTONIC, &start);
  for (;;) {
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd >= 0) {
      if (connect(fd, (struct sockaddr *)&a, sizeof a) == 0) { close(fd); return 0; }
      close(fd);
    }
    clock_gettime(CLOCK_MONOTONIC, &now);
    if ((now.tv_sec - start.tv_sec) * 1000 + (now.tv_nsec - start.tv_nsec) / 1000000 >= timeout_ms)
      return 1;
    nanosleep(&delay, NULL);
  }
}
static void js_session_child(int gate, int devnull, const char *cwd, unsigned gid,
    unsigned uid, const gid_t *groups, int ngroups, const char *exe,
    char *const argv[], char *const envp[], const char *probe, int probe_timeout) {
  char token; ssize_t n; long maxfd; int fd;
  if (setsid() < 0) _exit(126);
  do { n = read(gate, &token, 1); } while (n < 0 && errno == EINTR);
  if (n != 1 || token != 'x') _exit(126);
  if (dup2(devnull, 0) < 0 || dup2(devnull, 1) < 0 || dup2(devnull, 2) < 0) _exit(126);
  maxfd = sysconf(_SC_OPEN_MAX);
  if (maxfd < 3 || maxfd > 65536) maxfd = 65536;
  for (fd = 3; fd < maxfd; fd++) close(fd);
  if (js_drop_identity(gid, uid, groups, ngroups) != 0) _exit(126);
  if (chdir(cwd) != 0) _exit(126);
  if (probe) _exit(js_probe_unix(probe, probe_timeout));
  execve(exe, argv, envp);
  _exit(127);
}
static int js_mount_tmpfs(const char *path, const char *data) {
  return mount("tmpfs", path, "tmpfs", MS_NOSUID | MS_NODEV, data) == 0 ? 0 : errno;
}
static int js_umount(const char *path, int detach) {
  return umount2(path, detach ? MNT_DETACH : 0) == 0 ? 0 : errno;
}
""".}
  proc cSessionChild(gate, devnull: cint; cwd: cstring; gid, uid: cuint;
                     groups: ptr Gid; ngroups: cint; exe: cstring;
                     argv, envp: cstringArray; probe: cstring;
                     probeTimeout: cint) {.importc: "js_session_child", nodecl, noreturn.}
  proc cMountTmpfs(path, data: cstring): cint {.importc: "js_mount_tmpfs", nodecl.}
  proc cUmount(path: cstring; detach: cint): cint {.importc: "js_umount", nodecl.}
  proc cGetGroupList(user: cstring; group: Gid; groups: ptr Gid;
                     ngroups: ptr cint): cint {.importc: "getgrouplist", header: "<grp.h>".}

  proc supplementaryGroups*(account: AccountInfo): seq[Gid] =
    ## initgroups(3) equivalent computed before fork: the account's groups
    ## from the group database, including its primary GID.
    var count: cint = 64
    while true:
      result = newSeq[Gid](int(count))
      var n = count
      if cGetGroupList(account.name.cstring, Gid(account.gid), addr result[0], addr n) >= 0:
        result.setLen(int(n))
        return
      if n <= count: raise newCoreError(ecBackend, "getgrouplist failed for " & account.name)
      count = n

  proc forkAsUser(runtime: LinuxSessionRuntime; account: AccountInfo;
                  groups: seq[Gid]; cgroupProcs: string; probe: string;
                  probeTimeoutMs: int; owner: string;
                  callback: ChildCallback): Pid =
    ## One fork path for the daemon and the readiness probe. The child waits
    ## on a gate until it is registered with the reaper and placed in its
    ## cgroup, so it can neither exit unobserved nor run outside its cgroup.
    let exe = runtime.config.jumpstartExecutable
    # §7.5 user-mode base environment; RUNTIME is /run/user/UID (just
    # mounted), so XDG_RUNTIME_DIR is set. Nothing of our own environment.
    let identity = UserIdentity(uid: int(account.uid), home: account.home,
      user: account.name, logname: account.name, shell: account.shell)
    let runtimeDir = canonicalRuntimeDirFor(int(account.uid))
    let canonical = runtime.runtimeDirFor(account.uid) == runtimeDir
    var argvStore = @[exe, "--user"]
    let envStore = environmentVector(baseEnvironment(cmUser, identity,
      if canonical: runtimeDir else: "", canonical))
    var argv = newSeq[cstring](argvStore.len + 1)
    var envp = newSeq[cstring](envStore.len + 1)
    for i in 0 ..< argvStore.len: argv[i] = argvStore[i].cstring
    for i in 0 ..< envStore.len: envp[i] = envStore[i].cstring
    var groupStore = groups
    if groupStore.len == 0: groupStore.add Gid(account.gid)
    let probePath = probe
    let probeC: cstring = if probePath.len == 0: nil else: probePath.cstring
    let home = account.home
    var gate: array[2, cint]
    if posix.pipe(gate) != 0: raiseOSError(osLastError())
    discard fcntl(gate[1], F_SETFD, FD_CLOEXEC)
    let devnull = posix.open("/dev/null", O_RDWR or O_CLOEXEC)
    if devnull < 0:
      discard posix.close(gate[0]); discard posix.close(gate[1])
      raiseOSError(osLastError(), "/dev/null")
    let pid = fork()
    if pid < 0:
      let err = osLastError()
      discard posix.close(gate[0]); discard posix.close(gate[1]); discard posix.close(devnull)
      raiseOSError(err)
    if pid == 0:
      cSessionChild(gate[0], devnull, home.cstring, cuint(account.gid),
        cuint(account.uid), addr groupStore[0], cint(groupStore.len), exe.cstring,
        cast[cstringArray](addr argv[0]), cast[cstringArray](addr envp[0]),
        probeC, cint(probeTimeoutMs))
    discard posix.close(gate[0])
    discard posix.close(devnull)
    try:
      runtime.config.reaper.register(pid, owner, callback)
      if cgroupProcs.len > 0:
        runtime.config.cgroupSystem.writeFile(cgroupProcs, $pid)
      var token = 'x'
      if posix.write(gate[1], addr token, 1) != 1: raiseOSError(osLastError())
    except:
      discard posix.kill(pid, SIGKILL)
      discard posix.close(gate[1])
      raise
    discard posix.close(gate[1])
    pid

  proc pumpReaper(runtime: LinuxSessionRuntime) =
    let r = runtime.config.reaper
    if r.sigChldPending: discard r.drainWakeup() else: discard r.drain()

  proc socketPathFor(runtime: LinuxSessionRuntime; account: AccountInfo): string =
    account.home / runtime.config.socketRelative

  proc probeSocket(runtime: LinuxSessionRuntime; account: AccountInfo;
                   groups: seq[Gid]; timeoutMs: int): bool =
    ## Connect to the user socket as the user, in a child process.
    var done = false
    var status: ChildStatus
    let pid = runtime.forkAsUser(account, groups, "", runtime.socketPathFor(account),
      timeoutMs, "user:" & $account.uid & "/probe",
      proc(s: ChildStatus) =
        done = true
        status = s)
    let deadline = runtime.config.now() + int64(timeoutMs) + UserKillReapMs
    while not done:
      runtime.pumpReaper()
      if done: break
      if runtime.config.now() >= deadline:
        discard runtime.config.reaper.signalChild(pid, SIGKILL)
      runtime.config.pause(10)
    status.kind == cekExited and status.code == 0

  proc ensureRunUserRoot(runtime: LinuxSessionRuntime) =
    let root = runtime.config.runUserRoot
    var st: Stat
    if lstat(root.cstring, st) != 0:
      if posix.mkdir(root.cstring, Mode(0o755)) != 0 and osLastError() != OSErrorCode(EEXIST):
        raise newCoreError(ecIo, "cannot create " & root & ": " & osErrorMsg(osLastError()))
      if posix.chmod(root.cstring, Mode(0o755)) != 0:
        raise newCoreError(ecIo, "cannot set mode of " & root)
      if lstat(root.cstring, st) != 0:
        raise newCoreError(ecIo, "cannot stat " & root)
    if not S_ISDIR(st.st_mode) or st.st_uid != geteuid() or
        (st.st_mode and Mode(0o022)) != 0:
      raise newCoreError(ecPermission, root & " is not a root-owned 0755 directory")

  proc mountInfo(runtime: LinuxSessionRuntime): string =
    readFile(runtime.config.mountInfoPath)

  proc prepareRuntimeDir(runtime: LinuxSessionRuntime; account: AccountInfo) =
    runtime.ensureRunUserRoot()
    let path = runtime.runtimeDirFor(account.uid)
    var st: Stat
    if lstat(path.cstring, st) == 0:
      if isJumpstartRuntimeMount(runtime.mountInfo, path, account.uid): return
      raise newCoreError(ecPermission, path & " already exists and is not a Jumpstart runtime mount")
    if posix.mkdir(path.cstring, Mode(0o700)) != 0:
      raise newCoreError(ecIo, "cannot create " & path & ": " & osErrorMsg(osLastError()))
    let code = cMountTmpfs(path.cstring, tmpfsData(account.uid, account.gid).cstring)
    if code != 0:
      discard posix.rmdir(path.cstring)
      raise newCoreError(ecIo, "cannot mount tmpfs on " & path & ": " & $strerror(code))

  proc releaseRuntimeDir(runtime: LinuxSessionRuntime; uid: SessionUid) =
    ## Unmount (lazily if busy) and remove the empty mount point. A directory
    ## that is not a mount is left alone: its files are never touched.
    let path = runtime.runtimeDirFor(uid)
    var info = ""
    try: info = runtime.mountInfo
    except CatchableError as e:
      runtime.say("cannot read mount table: " & e.msg)
      return
    if not mountEntry(info, path).found: return
    var code = cUmount(path.cstring, 0)
    if code == EBUSY:
      runtime.say(path & " is busy; detaching lazily")
      code = cUmount(path.cstring, 1)
    if code != 0:
      runtime.say("cannot unmount " & path & ": " & $strerror(code))
      return
    if posix.rmdir(path.cstring) != 0:
      runtime.say("cannot remove " & path & ": " & osErrorMsg(osLastError()))

  proc releaseCgroup(runtime: LinuxSessionRuntime; uid: SessionUid) =
    if runtime.config.usersCgroupRoot.len == 0: return
    try:
      killUserCgroups(userCgroups(runtime.config.usersCgroupRoot, int(uid)),
                      runtime.config.cgroupSystem)
    except CatchableError as e:
      runtime.say("cannot kill user cgroup of UID " & $uid & ": " & e.msg)

  proc prepareCgroup(runtime: LinuxSessionRuntime; account: AccountInfo): string =
    if runtime.config.usersCgroupRoot.len == 0: return ""
    let sys = runtime.config.cgroupSystem
    let existing = userCgroups(runtime.config.usersCgroupRoot, int(account.uid))
    if sys.isDir(existing.user): killUserCgroups(existing, sys)
    let layout = createUserCgroups(runtime.config.usersCgroupRoot, int(account.uid), sys)
    delegateUser(layout, int(account.uid), int(account.gid), sys)
    layout.daemon / "cgroup.procs"

  proc finishStop(runtime: LinuxSessionRuntime; uid: SessionUid) =
    ## Blocking completion of a requested stop (used when a new session
    ## arrives while the previous daemon is still stopping).
    while runtime.daemons.hasKey(uid) and runtime.daemons[uid].running:
      runtime.pumpReaper()
      let now = runtime.config.now()
      var record = runtime.daemons[uid]
      if not record.running: break
      if not record.killSent and now >= record.stopDeadline:
        discard runtime.config.reaper.signalChild(record.pid, SIGKILL)
        record.killSent = true
        record.stopDeadline = now + UserKillReapMs
        runtime.daemons[uid] = record
      elif record.killSent and now >= record.stopDeadline:
        runtime.say("user daemon of UID " & $uid & " did not exit after SIGKILL")
        break
      runtime.config.pause(10)

  proc tick*(runtime: LinuxSessionRuntime) =
    ## Event-loop hook (call after draining the reaper): escalates stops to
    ## SIGKILL at 30 s, and completes cleanup and exit reporting.
    let now = runtime.config.now()
    var uids: seq[SessionUid]
    for uid in runtime.daemons.keys: uids.add uid
    for uid in uids:
      var record = runtime.daemons[uid]
      if record.starting: continue
      if record.running and record.stopRequested and not record.killSent and
          now >= record.stopDeadline:
        discard runtime.config.reaper.signalChild(record.pid, SIGKILL)
        record.killSent = true
        runtime.daemons[uid] = record
      if record.exitPending:
        record.exitPending = false
        runtime.daemons[uid] = record
        runtime.releaseCgroup(uid)
        var socketInUse = false
        if record.stopRequested:
          runtime.releaseRuntimeDir(uid)
        elif not (record.exitStatus.kind == cekExited and record.exitStatus.code == 0):
          try:
            socketInUse = runtime.probeSocket(record.account,
              supplementaryGroups(record.account), 0)
          except CatchableError: socketInUse = false
        if not runtime.config.onExit.isNil:
          try: runtime.config.onExit(record.account, record.exitStatus,
                                     record.stopRequested, socketInUse)
          except CatchableError as e: runtime.say("exit handler failed: " & e.msg)

  proc start(runtime: LinuxSessionRuntime; account: AccountInfo;
             reason: StartReason): StartOutcome =
    let uid = account.uid
    if uid == 0: return soFailed
    if runtime.daemons.hasKey(uid) and runtime.daemons[uid].running:
      if runtime.daemons[uid].stopRequested:
        runtime.finishStop(uid)
        runtime.tick()
      else:
        return soStarted
    var groups: seq[Gid]
    var cgroupProcs = ""
    try:
      groups = supplementaryGroups(account)
      runtime.prepareRuntimeDir(account)
      cgroupProcs = runtime.prepareCgroup(account)
    except CatchableError as e:
      runtime.say("cannot prepare user daemon of " & account.name & " (" & $reason & "): " & e.msg)
      return soFailed
    var record = DaemonRecord(account: account, running: true, starting: true)
    runtime.daemons[uid] = record
    let rt = runtime
    try:
      record.pid = runtime.forkAsUser(account, groups, cgroupProcs, "", 0,
        "user:" & $uid & "/daemon",
        proc(status: ChildStatus) =
          if rt.daemons.hasKey(uid):
            rt.daemons[uid].running = false
            rt.daemons[uid].exitPending = true
            rt.daemons[uid].exitStatus = status)
    except CatchableError as e:
      runtime.daemons.del(uid)
      runtime.say("cannot spawn user daemon of " & account.name & ": " & e.msg)
      runtime.releaseCgroup(uid)
      return soFailed
    runtime.daemons[uid].pid = record.pid
    # §7.6 step 4.5: wait up to 10 s for the socket to accept connections.
    let ready = try: runtime.probeSocket(account, groups, int(UserSocketWaitMs))
                except CatchableError: false
    runtime.pumpReaper()
    let current = runtime.daemons[uid]
    if ready and current.running:
      runtime.daemons[uid].starting = false
      return soStarted
    if current.running:
      runtime.say("user daemon of " & account.name & " did not open its socket within 10 seconds")
      discard runtime.config.reaper.signalChild(current.pid, SIGKILL)
      let deadline = runtime.config.now() + UserKillReapMs
      while runtime.daemons[uid].running and runtime.config.now() < deadline:
        runtime.pumpReaper()
        runtime.config.pause(10)
      runtime.releaseCgroup(uid)
      runtime.daemons.del(uid)
      return soFailed
    # The new daemon exited during start-up. If the socket still accepts, a
    # hand-started daemon holds it (§7.6 step 8): report and leave it alone.
    runtime.releaseCgroup(uid)
    runtime.daemons.del(uid)
    let inUse = try: runtime.probeSocket(account, groups, 0)
                except CatchableError: false
    if inUse:
      runtime.say("user socket of " & account.name & " is held by another daemon")
      return soSocketInUse
    runtime.say("user daemon of " & account.name & " exited during start-up (status " &
      $current.exitStatus.code & ")")
    soFailed

  proc stop(runtime: LinuxSessionRuntime; account: AccountInfo) =
    ## §7.6 step 5, non-blocking: SIGTERM now; `tick` sends SIGKILL after 30 s
    ## and releases the cgroup and runtime mount once the daemon exited. A
    ## user without a running daemon is cleaned up immediately.
    let uid = account.uid
    if runtime.daemons.hasKey(uid) and runtime.daemons[uid].running:
      if runtime.daemons[uid].stopRequested: return
      runtime.daemons[uid].stopRequested = true
      runtime.daemons[uid].stopDeadline = runtime.config.now() + UserStopGraceMs
      discard runtime.config.reaper.signalChild(runtime.daemons[uid].pid, SIGTERM)
    else:
      runtime.daemons.del(uid)
      runtime.releaseCgroup(uid)
      runtime.releaseRuntimeDir(uid)

  proc newLinuxSessionRuntime*(config: LinuxSessionConfig): LinuxSessionRuntime =
    if config.jumpstartExecutable.len == 0 or not config.jumpstartExecutable.isAbsolute:
      raise newException(ValueError, "the jumpstart executable path must be absolute")
    if config.reaper.isNil or config.now.isNil or config.pause.isNil:
      raise newException(ValueError, "session runtime requires a reaper, clock and pause")
    if config.runUserRoot.len == 0 or not config.runUserRoot.isAbsolute:
      raise newException(ValueError, "the /run/user root must be absolute")
    if config.socketRelative.len == 0 or config.socketRelative.isAbsolute:
      raise newException(ValueError, "the user socket path must be relative to home")
    if config.mountInfoPath.len == 0:
      raise newException(ValueError, "a mount table path is required")
    if config.usersCgroupRoot.len > 0 and config.cgroupSystem.exists.isNil:
      raise newException(ValueError, "cgroup delegation requires a cgroup system")
    LinuxSessionRuntime(config: config, daemons: initTable[SessionUid, DaemonRecord]())

  proc ops*(runtime: LinuxSessionRuntime): SessionRuntimeOps =
    SessionRuntimeOps(
      start: proc(account: AccountInfo; reason: StartReason): StartOutcome =
        runtime.start(account, reason),
      stop: proc(account: AccountInfo) = runtime.stop(account))

  proc stopping*(runtime: LinuxSessionRuntime; uid: SessionUid): bool =
    runtime.daemons.hasKey(uid) and runtime.daemons[uid].running and
      runtime.daemons[uid].stopRequested

else:
  proc newLinuxSessionRuntime*(config: LinuxSessionConfig): LinuxSessionRuntime =
    discard config
    raise newException(OSError, "user daemon sessions require Linux")

  proc ops*(runtime: LinuxSessionRuntime): SessionRuntimeOps =
    discard runtime
    raise newException(OSError, "user daemon sessions require Linux")

  proc tick*(runtime: LinuxSessionRuntime) = discard runtime

  proc stopping*(runtime: LinuxSessionRuntime; uid: SessionUid): bool = false
