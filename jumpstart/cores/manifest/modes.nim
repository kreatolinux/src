## Core operating-mode selection and injectable path construction.
import std/[os, posix]
import jumpstartcore/coremode
export coremode

const jumpstartLibDir* {.strdefine.} = "/usr/lib"
  ## Compile-time library directory (`-d:jumpstartLibDir`, from build.sh's
  ## JUMPSTART_LIBDIR). The system core root and the Kongue runner live below
  ## it (§7.2, §16.1, §25).

const
  systemCoreRootDefault* = jumpstartLibDir & "/jumpstart/cores"
  kongueRunnerDefault* = jumpstartLibDir & "/jumpstart/kongue-runner"

type
  ModeError* = object of ValueError

  PasswdHomeLookup* = proc(uid: int): string {.closure.}
  RuntimeDirCheck* = proc(path: string, uid: int): bool {.closure.}

  CorePathRoots* = object
    ## Root inputs are explicit so tests and embedders need not touch host paths.
    systemCoreRoot*: string
    systemConfigRoot*: string
    systemStateRoot*: string
    systemRuntimeRoot*: string
    systemCgroupRoot*: string
    systemLogPath*: string
    systemSocketPath*: string
    lingerRoot*: string
    userCoreRelative*: string
    userConfigRelative*: string
    userStateRelative*: string
    userDataRelative*: string
    fallbackRuntimeRelative*: string
    userCgroupRoot*: string

  CorePaths* = object
    mode*: CoreMode
    uid*: int
    home*: string
    coreRoots*: seq[string]
    configRoot*, enabledRoot*, stateLock*: string
    stateRoot*, runtimeRoot*, nameIndexRoot*: string
    cgroupRoot*, logPath*, socketPath*, socketDir*: string
    lingerRoot*: string
      ## Empty in user mode: lingering is a system-mode feature (§7.2, §21.8).
    runtimeDir*: string
      ## User mode: the selected RUNTIME (§7.2). System mode: the system
      ## runtime root (/run/jumpstart).
    fallbackRuntime*: bool

proc defaultCorePathRoots*(): CorePathRoots =
  CorePathRoots(
    systemCoreRoot: systemCoreRootDefault,
    systemConfigRoot: "/etc/jumpstart",
    systemStateRoot: "/var/lib/jumpstart",
    systemRuntimeRoot: "/run/jumpstart",
    systemCgroupRoot: "/sys/fs/cgroup/jumpstart",
    systemLogPath: "/var/log/jumpstart.log",
    systemSocketPath: "/run/jumpstart.sock",
    lingerRoot: "/etc/jumpstart/users/linger",
    userCoreRelative: ".local/lib/jumpstart/cores",
    userConfigRelative: ".config/jumpstart",
    userStateRelative: ".local/state/jumpstart",
    userDataRelative: ".local/share/jumpstart",
    fallbackRuntimeRelative: ".local/share/jumpstart/runtime",
    userCgroupRoot: "/sys/fs/cgroup/jumpstart/users")

proc requireUid(uid: int) =
  if uid < 0 or uint64(uid) > uint64(high(Uid)):
    raise newException(ModeError, "real UID is outside uid_t range")

proc daemonMode*(userFlag: bool, realUid: int): CoreMode =
  ## Enforce the daemon mode/real-UID combinations from section 7.1.
  requireUid(realUid)
  if userFlag:
    if realUid == 0:
      raise newException(ModeError, "--user requires a non-root real UID")
    cmUser
  else:
    if realUid != 0:
      raise newException(ModeError, "system mode requires real UID 0")
    cmSystem

proc clientMode*(realUid: int): CoreMode =
  requireUid(realUid)
  if realUid == 0: cmSystem else: cmUser

proc passwdHome*(uid: int): string =
  ## Return the home recorded for `uid` in the password database. Environment
  ## variables are deliberately not consulted.
  requireUid(uid)
  let entry = getpwuid(Uid(uid))
  if entry == nil or entry.pwDir == nil or entry.pwDir[0] == '\0':
    raise newException(ModeError, "no password-database home for UID " & $uid)
  result = $entry.pwDir
  if not result.isAbsolute:
    raise newException(ModeError,
      "password-database home for UID " & $uid & " is not absolute")


proc runtimeDirIsValid*(path: string, uid: int): bool =
  ## Linux runtime directories are usable only when they are directories,
  ## owned by the real user, and exactly mode 0700 (§7.2).
  requireUid(uid)
  var info: Stat
  if stat(path, info) != 0:
    return false
  S_ISDIR(info.st_mode) and info.st_uid == Uid(uid) and
    (info.st_mode and Mode(0o777)) == Mode(0o700)

proc selectRuntimeDir*(uid: int, home: string,
                       roots: CorePathRoots = defaultCorePathRoots(),
                       runtimeBase = "/run/user",
                       check: RuntimeDirCheck = nil): string =
  ## Select /run/user/UID only after validating Linux ownership and mode.
  ## The checker and runtime base are injectable for container tests.
  requireUid(uid)
  if home.len == 0 or not home.isAbsolute:
    raise newException(ModeError, "an absolute password-database home is required")
  let candidate = runtimeBase / $uid
  let valid = if check == nil: runtimeDirIsValid(candidate, uid)
              else: check(candidate, uid)
  if valid: candidate else: home / roots.fallbackRuntimeRelative

proc pathsFor*(mode: CoreMode, uid: int, home: string = "",
               validRuntimeDir: string = "",
               roots: CorePathRoots = defaultCorePathRoots()): CorePaths =
  ## Build paths without consulting HOME, XDG variables, or the filesystem.
  ## `home` is supplied from the password database by the caller. A verified
  ## /run/user/UID path may be supplied in `validRuntimeDir`.
  requireUid(uid)
  result.mode = mode
  result.uid = uid
  result.home = home
  case mode
  of cmSystem:
    if uid != 0:
      raise newException(ModeError, "system paths require UID 0")
    result.coreRoots = @[roots.systemCoreRoot]
    result.configRoot = roots.systemConfigRoot
    result.enabledRoot = roots.systemConfigRoot / "cores" / "enabled"
    result.stateLock = roots.systemConfigRoot / "cores" / ".lock"
    result.stateRoot = roots.systemStateRoot / "cores"
    result.runtimeRoot = roots.systemRuntimeRoot / "cores"
    result.nameIndexRoot = roots.systemRuntimeRoot / "name-index"
    result.cgroupRoot = roots.systemCgroupRoot / "cores"
    result.logPath = roots.systemLogPath
    result.socketPath = roots.systemSocketPath
    result.socketDir = parentDir(roots.systemSocketPath)
    result.lingerRoot = roots.lingerRoot
    result.runtimeDir = roots.systemRuntimeRoot
  of cmUser:
    if uid == 0:
      raise newException(ModeError, "user paths require a non-root UID")
    if home.len == 0 or not home.isAbsolute:
      raise newException(ModeError, "an absolute password-database home is required")
    if validRuntimeDir.len > 0 and not validRuntimeDir.isAbsolute:
      raise newException(ModeError, "verified runtime directory must be absolute")
    let dataRoot = home / roots.userDataRelative
    let runtime = if validRuntimeDir.len > 0: validRuntimeDir
                  else: home / roots.fallbackRuntimeRelative
    result.coreRoots = @[roots.systemCoreRoot, home / roots.userCoreRelative]
    result.configRoot = home / roots.userConfigRelative
    result.enabledRoot = result.configRoot / "cores" / "enabled"
    result.stateLock = result.configRoot / "cores" / ".lock"
    result.stateRoot = home / roots.userStateRelative / "cores"
    result.runtimeRoot = runtime / "jumpstart" / "cores"
    result.nameIndexRoot = runtime / "jumpstart" / "name-index"
    result.cgroupRoot = roots.userCgroupRoot / $uid / "cores"
    result.logPath = home / roots.userStateRelative / "jumpstart.log"
    result.socketDir = dataRoot
    result.socketPath = dataRoot / "jumpstart.sock"
    result.runtimeDir = runtime
    result.fallbackRuntime = validRuntimeDir.len == 0


proc pathsForPasswd*(mode: CoreMode, uid: int,
                     validRuntimeDir: string = "",
                     roots: CorePathRoots = defaultCorePathRoots(),
                     homeLookup: PasswdHomeLookup = nil,
                     runtimeBase = "/run/user",
                     runtimeCheck: RuntimeDirCheck = nil): CorePaths =
  ## Password-database-backed entry point for production callers. `homeLookup`
  ## is injectable so tests never need to read a real account database.
  requireUid(uid)
  if mode == cmSystem:
    return pathsFor(mode, uid, roots = roots)
  let home = if homeLookup == nil: passwdHome(uid) else: homeLookup(uid)
  let runtime = if validRuntimeDir.len > 0: validRuntimeDir
                else: selectRuntimeDir(uid, home, roots, runtimeBase, runtimeCheck)
  let fallback = home / roots.fallbackRuntimeRelative
  pathsFor(mode, uid, home, if runtime == fallback: "" else: runtime, roots)


# Mode-dependent checks and startup helpers ----------------------------------

proc lingerAvailable*(paths: CorePaths): bool =
  paths.mode == cmSystem and paths.lingerRoot.len > 0

proc requireLinger*(paths: CorePaths) =
  ## `users linger` exists only in system mode; callers map ModeError to exit
  ## status 2 (§21.8, §27.10).
  if not paths.lingerAvailable:
    raise newException(ModeError, "users linger is available only in system mode")

proc lstatOk(path: string; info: var Stat): bool =
  lstat(path.cstring, info) == 0

proc removeEntryNoFollow(path: string) =
  var info: Stat
  if not lstatOk(path, info): return
  if S_ISDIR(info.st_mode):
    for kind, child in walkDir(path):
      removeEntryNoFollow(child)
    if posix.rmdir(path.cstring) != 0: raiseOSError(osLastError(), path)
  else:
    if posix.unlink(path.cstring) != 0: raiseOSError(osLastError(), path)

proc ensurePrivateDir*(path: string; uid: int) =
  ## Create (with parents) or verify a directory that must be a real
  ## directory owned by uid with mode exactly 0700: the user socket directory
  ## and the fallback RUNTIME (§7.2, §7.4 rule 6). Refuses symlinks and
  ## directories owned by anyone else.
  requireUid(uid)
  if path.len == 0 or not path.isAbsolute:
    raise newException(ModeError, "private directory path must be absolute")
  var info: Stat
  if not lstatOk(path, info):
    let parent = parentDir(path)
    if not dirExists(parent): createDir(parent)
    if posix.mkdir(path.cstring, Mode(0o700)) != 0 and osLastError() != OSErrorCode(EEXIST):
      raiseOSError(osLastError(), path)
    if not lstatOk(path, info): raiseOSError(osLastError(), path)
  if not S_ISDIR(info.st_mode):
    raise newException(ModeError, path & " is not a directory")
  if info.st_uid != Uid(uid):
    raise newException(ModeError, path & " is not owned by UID " & $uid)
  if (info.st_mode and Mode(0o777)) != Mode(0o700):
    if posix.chmod(path.cstring, Mode(0o700)) != 0: raiseOSError(osLastError(), path)

proc emptyFallbackRuntime*(paths: CorePaths): bool =
  ## §7.2/§20.2: a user daemon using the fallback RUNTIME empties it at
  ## startup, because it lives on persistent storage. Symbolic links are
  ## removed, never followed. Returns true when the fallback is in use.
  if paths.mode != cmUser or not paths.fallbackRuntime: return false
  ensurePrivateDir(paths.runtimeDir, paths.uid)
  for kind, child in walkDir(paths.runtimeDir):
    removeEntryNoFollow(child)
  true

proc cRename(source, target: cstring): cint {.importc: "rename", header: "<stdio.h>".}

type
  SocketInUseError* = object of IOError
    ## Another live daemon accepts connections on the socket (§7.6 step 8).
  SocketProbe* = enum
    spMissing,   ## nothing at the path
    spStale      ## a dead socket was found and unlinked

proc fillAddress(path: string; address: var Sockaddr_un) =
  if path.len == 0 or path.len >= address.sun_path.len:
    raise newException(ModeError, "socket path is empty or too long: " & path)
  zeroMem(addr address, sizeof(address))
  address.sun_family = TSa_Family(posix.AF_UNIX)
  for i, c in path: address.sun_path[i] = c

proc socketAccepts*(path: string): bool =
  ## Connect once; true when a listener accepted the connection.
  var address: Sockaddr_un
  fillAddress(path, address)
  let fd = posix.socket(posix.AF_UNIX, posix.SOCK_STREAM, 0)
  if fd == SocketHandle(-1): raiseOSError(osLastError(), "socket")
  defer: discard posix.close(fd)
  posix.connect(fd, cast[ptr SockAddr](addr address),
                SockLen(sizeof(address))) == 0

proc probeExistingSocket*(path: string): SocketProbe =
  ## §7.6 steps 7-8 and startup: a live socket (one that accepts a
  ## connection) raises SocketInUseError and is left alone; a dead socket is
  ## unlinked; anything that is not a socket is refused.
  var info: Stat
  if not lstatOk(path, info): return spMissing
  if not S_ISSOCK(info.st_mode):
    raise newException(ModeError, path & " exists and is not a socket")
  if socketAccepts(path):
    raise newException(SocketInUseError, "socket is in use by a running daemon: " & path)
  if posix.unlink(path.cstring) != 0 and osLastError() != OSErrorCode(ENOENT):
    raiseOSError(osLastError(), path)
  spStale

proc bindControlSocket*(path: string; backlog = 128): SocketHandle =
  ## Create the control socket with mode 0600 and no window in which it is
  ## reachable with umask-derived permissions (§7.4 rules 5-6): bind inside a
  ## fresh 0700 directory next to the final path, chmod 0600, then rename
  ## into place atomically. A live socket at `path` raises SocketInUseError;
  ## a stale one is replaced. Returns a listening, close-on-exec descriptor.
  if path.len == 0 or not path.isAbsolute:
    raise newException(ModeError, "socket path must be absolute")
  discard probeExistingSocket(path)
  var templ = parentDir(path) / ".jumpstart-sock-XXXXXX"
  if mkdtemp(templ.cstring) == nil: raiseOSError(osLastError(), templ)
  let staging = templ / "s"
  var address: Sockaddr_un
  var fd = SocketHandle(-1)
  try:
    fillAddress(staging, address)
    fd = posix.socket(posix.AF_UNIX, posix.SOCK_STREAM, 0)
    if fd == SocketHandle(-1): raiseOSError(osLastError(), "socket")
    discard fcntl(cint(fd), F_SETFD, FD_CLOEXEC)
    if posix.bindSocket(fd, cast[ptr SockAddr](addr address),
                        SockLen(sizeof(address))) != 0:
      raiseOSError(osLastError(), staging)
    if posix.chmod(staging.cstring, Mode(0o600)) != 0:
      raiseOSError(osLastError(), staging)
    if posix.listen(fd, cint(backlog)) != 0: raiseOSError(osLastError(), staging)
    if cRename(staging.cstring, path.cstring) != 0:
      raiseOSError(osLastError(), path)
    discard posix.rmdir(templ.cstring)
    result = fd
  except:
    if fd != SocketHandle(-1): discard posix.close(fd)
    discard posix.unlink(staging.cstring)
    discard posix.rmdir(templ.cstring)
    raise
