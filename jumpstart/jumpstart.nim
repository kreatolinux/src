## The Jumpstart daemon executable (§7, §20.2).
##
## `jumpstart` runs as PID 1 (system mode); `jumpstart --user` runs as a
## user's daemon. This file selects the mode and paths, performs the PID 1
## duties, binds the control socket, wires the runtimes together and hands
## control to the event loop in cores/daemon/daemon.nim. It never runs processes
## itself and never blocks outside that loop.
import std/[os, posix, strutils]
import commonImports
import serviceHandler/main
import cores/backends/[adapter_runtime, backend_runtime],
  cores/manifest/[coredirs, manifest, discovery, modes],
  cores/daemon/[daemon, logging, shutdown, shutdown_linux],
  cores/sessions/[lingerfs, session_manager, session_runtime_linux, sessions],
  cores/lifecycle/state
import jumpstartcore/[cgroups, environment, errors, reaper, spawn]

proc usage(message: string) {.noreturn.} =
  stderr.writeLine("jumpstart: " & message)
  quit(2)

proc reapForever() {.noreturn.} =
  ## PID 1 must never exit (the kernel panics), whatever failed: the last
  ## resort keeps reaping orphans.
  while true:
    var status: cint
    while waitpid(Pid(-1), status, WNOHANG) > 0: discard
    sleep(500)

# Whatever escapes the guards below (an exception outside any `try`, a Defect),
# PID 1 must not exit: that is a kernel panic. The hook runs before the runtime
# terminates the program, so it logs and keeps reaping instead.
let initGuard = getCurrentProcessId() == 1
when not defined(jumpstartTestHooks):
  if initGuard:
    unhandledExceptionHook = proc(e: ref Exception) {.nimcall, gcsafe, raises: [], tags: [].} =
      {.cast(tags: []).}:
        try: stderr.writeLine("jumpstart: unhandled exception in PID 1: " & e.msg)
        except Exception: discard
        reapForever()

# The kernel hands the leftovers of its command line to init as arguments
# (`single`, `emergency`, ...): PID 1 ignores them instead of refusing to boot.
let runsAsInit = getCurrentProcessId() == 1
var userFlag = false
if not runsAsInit:
  if paramCount() > 1: usage("too many arguments")
  if paramCount() == 1:
    if paramStr(1) != "--user": usage("unknown argument: " & paramStr(1))
    userFlag = true

let realUid = int(getuid())
var mode: CoreMode
var paths: CorePaths
var testHooks = false
var trustedOwner = Uid(realUid)      # owner of the user core root and state
var systemOwner = Uid(0)             # owner of the system core root
var runnerPath = jumpstartLibDir / "jumpstart" / "kongue-runner"
var runnerOwner = Uid(0)
var testCgroup = ""
var testFilesystemsReady = true   # test builds: JUMPSTART_TEST_FS_READY=0
var testFstab = ""                # test builds: JUMPSTART_TEST_FSTAB / _MOUNTINFO
var testMountInfo = ""
var testFsWaitMs = 0'i64          # test builds: JUMPSTART_TEST_FS_WAIT_MS

when defined(jumpstartTestHooks):
  # Test builds only: every path lives under JUMPSTART_TEST_ROOT (the layout
  # matches jumpctl's -d:jumpctlTestHooks), files are owned by the test user
  # and no PID 1 duty runs. Production builds have no such inputs (§7.1).
  testHooks = true
  let testRoot = getEnv("JUMPSTART_TEST_ROOT")
  if testRoot.len == 0 or not testRoot.isAbsolute:
    usage("JUMPSTART_TEST_ROOT must be an absolute path")
  testCgroup = getEnv("JUMPSTART_TEST_CGROUP")
  testFilesystemsReady = getEnv("JUMPSTART_TEST_FS_READY") != "0"
  testFstab = getEnv("JUMPSTART_TEST_FSTAB")
  testMountInfo = getEnv("JUMPSTART_TEST_MOUNTINFO")
  if getEnv("JUMPSTART_TEST_FS_WAIT_MS").len > 0:
    testFsWaitMs = int64(parseInt(getEnv("JUMPSTART_TEST_FS_WAIT_MS")))
  let testRoots = CorePathRoots(systemCoreRoot: testRoot / "lib/cores",
    systemConfigRoot: testRoot / "etc", systemStateRoot: testRoot / "var",
    systemRuntimeRoot: testRoot / "run",
    systemCgroupRoot: (if testCgroup.len > 0: testCgroup / "jumpstart" else: testRoot / "cgroup"),
    systemLogPath: testRoot / "log", systemSocketPath: testRoot / "jumpstart.sock",
    lingerRoot: testRoot / "etc/users/linger", userCoreRelative: "cores",
    userConfigRelative: "config", userStateRelative: "state",
    userDataRelative: "data", fallbackRuntimeRelative: "runtime",
    userCgroupRoot: (if testCgroup.len > 0: testCgroup / "jumpstart/users"
                     else: testRoot / "cgroup/users"))
  let userUid = if realUid == 0: 65534 else: realUid
  mode = if getEnv("JUMPSTART_TEST_MODE") == "system": cmSystem else: cmUser
  paths = if mode == cmSystem: pathsFor(cmSystem, 0, roots = testRoots)
          else: pathsFor(cmUser, userUid, testRoot / "home", roots = testRoots)
  systemOwner = Uid(realUid)
  runnerPath = getEnv("JUMPSTART_TEST_RUNNER")
  runnerOwner = Uid(realUid)
else:
  try:
    mode = daemonMode(userFlag, realUid)
    paths = pathsForPasswd(mode, realUid)
  except ModeError as e:
    usage(e.msg)
  if mode == cmSystem and getCurrentProcessId() != 1:
    usage("system mode must run as PID 1")

# §7.4 rules 5-6: system mode serves UID 0, user mode the daemon's user.
var trustedPeer = if mode == cmSystem and not testHooks: 0 else: realUid
when defined(jumpstartTestHooks):
  # Lets tests check that other UIDs are rejected.
  if getEnv("JUMPSTART_TEST_TRUSTED_UID").len > 0:
    trustedPeer = parseInt(getEnv("JUMPSTART_TEST_TRUSTED_UID"))

# serviceHandler keeps its historical runtime layout beneath the daemon's
# runtime directory.
let nativeRuntime = if mode == cmSystem and not testHooks: "/run/serviceHandler"
                    else: paths.runtimeDir / "serviceHandler"
configureJumpstartPaths(paths.socketPath, paths.configRoot, nativeRuntime)
try: initServiceHandlerLogging(paths.logPath)
except Exception: discard         # the daemon log (below) still reports

# §19.2: the daemon log. System mode buffers until filesystems are ready. A
# logger that cannot be built degrades to one that only writes to stderr: the
# daemon (possibly PID 1) must boot either way.
proc buildLogger(): CoreLogger =
  try: return newDaemonLogger(paths)
  except Exception as e:
    stderr.writeLine("jumpstart: daemon log unavailable: " & e.msg)
  var config = defaultCoreLogConfig("")
  config.filesystemsReady = false
  newCoreLogger(config, proc(path, data: string) = stderr.write(data))
let logger = buildLogger()
when defined(jumpstartTestHooks):
  if getEnv("JUMPSTART_TEST_DEBUG").len > 0: logger.minimumLevel = clDebug
proc say(level: CoreLogLevel; message: string) =
  try: logger.log(level, "jumpstart", message)
  except Exception: discard

# Writes to a closed client never kill the daemon.
signal(SIGPIPE, SIG_IGN)

# The central reaper owns every child (§15.3).
var coreReaper: Reaper
try: coreReaper = newReaper()
except Exception as e:
  say(clError, "cannot create the reaper: " & e.msg)
  if runsAsInit and not testHooks: reapForever()
  quit(1)
try:
  installReaper(coreReaper, isPid1 = mode == cmSystem and not testHooks)
except Exception as e:
  # Child subreapers are Linux-only; elsewhere orphans go to init.
  say(clWarn, e.msg)
  try: coreReaper.installSigChldHandler()
  except Exception as inner: say(clError, "cannot install the SIGCHLD handler: " & inner.msg)

# §20.2 step 1: PID 1 duties. serviceHandler's initSystem is the single owner
# of the cgroup2 mount and of RB_DISABLE_CAD.
var filesystemsReady = mode == cmUser
var mountFstab = true
var cgroupsAvailable = false
var cgroupSys = defaultCgroupSystem()
# Waiting inside a cgroup kill or removal keeps the daemon's loop running
# (§14.5, §15.3); before the daemon exists there is nothing to run.
var coreDaemon: Daemon = nil
cgroupSys.pause = proc(ms: int) =
  if coreDaemon.isNil: sleep(ms) else: coreDaemon.pauseLoop(ms)
if mode == cmSystem:
  if testHooks:
    filesystemsReady = testFilesystemsReady
    mountFstab = testFilesystemsReady
    if testCgroup.len > 0:
      try:
        prepareSystemHierarchy(cgroupHierarchy(testCgroup), cgroupSys)
        cgroupsAvailable = true
      except Exception as e:
        say(clWarn, "test cgroup unavailable: " & e.msg)
  else:
    say(clInfo, "running in PID 1 mode")
    try:
      let init = initSystem(coreReaper)
      filesystemsReady = init.filesystemsReady
      mountFstab = init.mountFstab
      if init.cgroupAvailable:
        try:
          prepareSystemHierarchy(cgroupHierarchy(), cgroupSys)
          cgroupsAvailable = true
        except Exception as e:
          say(clWarn, "cgroup hierarchy unavailable: " & e.msg)
    except Exception as e:
      # Nothing is known to be mounted: write nothing persistent, run on.
      say(clError, "PID 1 initialization failed: " & e.msg)
      filesystemsReady = false
      mountFstab = false
else:
  say(clInfo, "running in user mode")
  if not testHooks or realUid == paths.uid:
    try: discard emptyFallbackRuntime(paths)
    except Exception as e: say(clWarn, "fallback runtime: " & e.msg)
  if not testHooks:
    try:
      cgroupsAvailable = userDelegationAvailable("/sys/fs/cgroup", realUid,
        readFile("/proc/self/cgroup"), cgroupSys)
    except Exception:
      cgroupsAvailable = false
  elif testCgroup.len > 0:
    # Test builds: a user daemon with a cgroup subtree the test provides.
    try:
      prepareSystemHierarchy(cgroupHierarchy(testCgroup), cgroupSys)
      discard createUserCgroups(testCgroup / "jumpstart/users", paths.uid, cgroupSys)
      cgroupsAvailable = true
    except Exception as e:
      say(clWarn, "test cgroup unavailable: " & e.msg)

# state.read requires the state parent to exist and be private. Each
# directory is set up on its own, so one failure never skips the others. On a
# read-only root the permission fix of an existing directory is impossible:
# that is warned about once and the directory is used as it is (the checks that
# read it still reject one that is not private or not owned correctly, §7.4,
# §8.3). Creating a missing directory that fails is an error.
var warnedReadOnlyDir = false
proc ensureDir(path: string; private = false) =
  try:
    ensureDaemonDir(path, private, proc(message: string) =
      if not warnedReadOnlyDir:
        warnedReadOnlyDir = true
        say(clWarn, message & " (further directories are not reported)"))
  except Exception as e:
    say(clError, "cannot create runtime directory " & path & ": " & e.msg)
ensureDir(paths.configRoot, private = mode == cmUser)
ensureDir(paths.configRoot / "cores", private = true)
ensureDir(paths.socketDir, private = mode == cmUser)
ensureDir(paths.runtimeDir, private = mode == cmUser)
ensureDir(paths.runtimeRoot, private = mode == cmUser)
ensureDir(paths.nameIndexRoot, private = true)
ensureDir(nativeRuntime, private = mode == cmUser)

# §20.2 step 2: the control socket, 0600, before discovery. A live socket
# means another daemon serves it. A user daemon then exits; the system daemon
# is PID 1 and keeps booting without a control socket (an exiting PID 1 is a
# kernel panic), logging why.
var listenFd: cint = -1
try:
  discard probeExistingSocket(paths.socketPath)
  listenFd = cint(bindControlSocket(paths.socketPath))
except SocketInUseError as e:
  say(clError, e.msg)
  discard logger.flush()
  stderr.writeLine("jumpstart: " & e.msg)
  if mode == cmUser: quit(1)
  say(clError, "continuing without a control socket")
except Exception as e:
  say(clError, "cannot bind control socket: " & e.msg)
  stderr.writeLine("jumpstart: cannot bind control socket: " & e.msg)
  if mode == cmUser: quit(1)

let shutdownMode = if mode == cmSystem: smSystem else: smUser
var triggerFd: cint = -1
try: triggerFd = installShutdownTriggers(shutdownMode)
except Exception as e:
  say(clError, "shutdown signals could not be installed: " & e.msg)

# The native serviceHandler core (Appendix A).
let nativeCtx = newNativeContext(paths.configRoot, nativeRuntime, coreReaper,
  socketPath = paths.socketPath, cgroupSystem = cgroupSys)
nativeCtx.pump = proc() =
  if coreDaemon.isNil:
    try: discard coreReaper.drain()
    except Exception: discard
  else: coreDaemon.nativePump()
let nativeCallbacks = serviceHandlerCallbacks(nativeCtx, jumpstartVersion)

var roots: seq[CoreRoot]
for i, root in paths.coreRoots:
  roots.add CoreRoot(path: root, trustedUid: trustedOwner,
                     isUserRoot: mode == cmUser and i > 0)

var runtimeConfig = RuntimeConfig(mode: mode,
  jumpstartVersion: runningVersionNumber(jumpstartVersion),
  runnerPath: runnerPath, runnerTrustedUid: runnerOwner,
  trustedUid: trustedOwner, runtimeDir: paths.runtimeDir)
if mode == cmUser:
  try: runtimeConfig.identity = userIdentityFor(Uid(paths.uid))
  except Exception:
    runtimeConfig.identity = UserIdentity(uid: paths.uid, home: paths.home)
  runtimeConfig.canonicalRuntimeDir = paths.runtimeDir == canonicalRuntimeDirFor(paths.uid)
else:
  runtimeConfig.forbiddenRoots = @["/home", "/root", paths.stateRoot, paths.runtimeRoot]

proc accountOf(core: string): CoreDirOwner =
  ## System mode: a core's `account` user owns its directories (§15.1 rule 4,
  ## §19.1); user mode: the daemon's user. An account that cannot be resolved
  ## fails the load with a clear error instead of leaving the directories
  ## owned by root.
  if mode == cmUser: return CoreDirOwner(uid: paths.uid, gid: int(getgid()))
  if testHooks or coreDaemon.isNil or core == "serviceHandler":
    return CoreDirOwner(uid: -1, gid: -1)
  let account = coreDaemon.manifestAccount(core)
  if account.len == 0:
    raise newCoreError(ecPermission,
      "the account of core " & core & " is unknown: refusing to create its directories", core)
  let entry = getpwnam(account.cstring)
  if entry.isNil:
    raise newCoreError(ecPermission, "account " & account & " of core " & core &
      " does not exist in the password database", core)
  CoreDirOwner(uid: int(entry.pw_uid), gid: int(entry.pw_gid))

# §20.3 step 5: nothing is created below a mount point that is not mounted
# yet. The fstab entries that are not in the mount table are pending, whether
# `mount_fstab` is on (a mount that failed) or off (cores mount later).
proc pendingMounts(): seq[string] =
  let fstabPath = if testHooks and testFstab.len > 0: testFstab else: "/etc/fstab"
  let infoPath = if testHooks and testMountInfo.len > 0: testMountInfo else: "/proc/self/mountinfo"
  if testHooks and testFstab.len == 0: return @[]
  if not fileExists(fstabPath): return @[]
  # An unreadable mount table raises: the state directory is retried later
  # rather than created where a mount might shadow it.
  pendingFstabMounts(readFile(fstabPath), readFile(infoPath))

var config = DaemonConfig(mode: mode, version: jumpstartVersion, paths: paths,
  roots: roots,
  statePaths: StatePaths(enabledDir: paths.enabledRoot, lockFile: paths.stateLock,
                         trustedUid: trustedOwner),
  discoveryOptions: DiscoveryOptions(systemOwner: systemOwner),
  trustedPeerUid: trustedPeer,
  cgroupsAvailable: cgroupsAvailable, cgroupMount: "/sys/fs/cgroup",
  cgroupSystem: cgroupSys, filesystemsReady: filesystemsReady,
  mountFstab: mountFstab, filesystemsWaitMs: testFsWaitMs, runtime: runtimeConfig, native: nativeCallbacks,
  logger: logger, account: accountOf, pendingMounts: pendingMounts,
  listenFd: listenFd, shutdownTriggerFd: triggerFd, procRoot: "/proc")
when defined(jumpstartTestHooks):
  let faultFile = getEnv("JUMPSTART_TEST_FAULT_FILE")
  if faultFile.len > 0:
    config.faultHook = proc() =
      if fileExists(faultFile):
        removeFile(faultFile)
        raise newException(ValueError, "injected event loop fault")

# System mode: §20.8 final sequence and §7.6 user sessions (Linux only).
var sessionRuntime: LinuxSessionRuntime = nil
when defined(linux):
  if mode == cmSystem and not testHooks:
    config.linuxShutdown = defaultLinuxShutdownConfig()
    config.linuxSystem = defaultLinuxShutdownSystem(proc() =
      try: discard coreReaper.drain()
      except Exception: discard)
    var sessionConfig = defaultLinuxSessionConfig(getAppFilename(), coreReaper,
      if cgroupsAvailable: cgroupHierarchy().users else: "")
    sessionConfig.now = proc(): int64 = monotonicMs()
    sessionConfig.pause = proc(ms: int) =
      if coreDaemon.isNil: sleep(ms) else: coreDaemon.runOnce(ms)
    sessionConfig.log = proc(message: string) = say(clInfo, "sessions: " & message)
    sessionConfig.onExit = proc(account: AccountInfo; status: ChildStatus;
                                causedBySystem, socketInUse: bool) =
      if coreDaemon.isNil or not coreDaemon.sessionsEnabled: return
      let outcome = coreDaemon.sessions.model.daemonExited(account.uid, status.code,
        causedBySystem, monotonicMs() div 1000, socketInUse)
      if not outcome.ok: say(clWarn, "user daemon " & $account.uid & ": " & outcome.message)
    try:
      sessionRuntime = newLinuxSessionRuntime(sessionConfig)
      let runtime = sessionRuntime
      config.sessions = SessionHooks(tick: proc() = runtime.tick(),
        runningUsers: proc(): seq[int] = runtime.runningUids())
      config.linuxShutdown.userPid = proc(uid: int): int = runtime.userPid(SessionUid(uid))
      config.linuxShutdown.userCgroup = proc(uid: int): string = runtime.userCgroup(SessionUid(uid))
    except Exception as e:
      say(clWarn, "user sessions unavailable: " & e.msg)
      sessionRuntime = nil

try:
  coreDaemon = newDaemon(config, coreReaper)
except Exception as e:
  say(clError, "cannot create the daemon: " & e.msg)
  discard logger.flush()
  if runsAsInit and not testHooks: reapForever()
  quit(1)

when defined(linux):
  if not sessionRuntime.isNil:
    try:
      coreDaemon.attachSessions(initSessionManager(passwdAccounts(), procPeerOps(),
        lingerFs(paths.lingerRoot, log = proc(message: string) = say(clWarn, message)),
        sessionRuntime.ops()))
    except Exception as e:
      say(clWarn, "user sessions unavailable: " & e.msg)

if listenFd >= 0:
  try: coreDaemon.attachTransport(listenFd)
  except Exception as e: say(clError, "cannot serve the control socket: " & e.msg)
say(clInfo, "Initializing " & jumpstartVersion)
coreDaemon.startup()

# Belt and braces: `serve` already guards every step of the loop, so nothing
# should end it early. If something still does, PID 1 keeps going.
var restarts = 0
while not coreDaemon.exitRequested:
  try:
    coreDaemon.serve()
  except Exception as e:
    inc restarts
    say(clError, "event loop restarted after: " & e.msg)
    sleep(min(restarts * 10, 250))

# User mode (and test builds) end here once the shutdown sequence finished;
# system mode's final action never returns.
discard logger.flush()
if runsAsInit and not testHooks:
  # The final reboot(2) failed: PID 1 may not exit.
  say(clError, "shutdown sequence ended without the system stopping")
  discard logger.flush()
  reapForever()
quit(coreDaemon.exitStatus)
