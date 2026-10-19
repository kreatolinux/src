import std/[os, unittest]
import ../../../../jumpstart/cores/manifest/modes

suite "core operating modes and paths":
  test "daemon mode enforces real UID":
    check daemonMode(false, 0) == cmSystem
    check daemonMode(true, 1000) == cmUser
    expect ModeError: discard daemonMode(true, 0)
    expect ModeError: discard daemonMode(false, 1000)
    check clientMode(0) == cmSystem
    check clientMode(1000) == cmUser
    expect ModeError: discard daemonMode(false, -1)
    expect ModeError: discard clientMode(-1)

  test "system paths are exact and do not include user roots":
    let paths = pathsFor(cmSystem, 0)
    check paths.coreRoots == @["/usr/lib/jumpstart/cores"]
    check paths.enabledRoot == "/etc/jumpstart/cores/enabled"
    check paths.stateLock == "/etc/jumpstart/cores/.lock"
    check paths.stateRoot == "/var/lib/jumpstart/cores"
    check paths.runtimeRoot == "/run/jumpstart/cores"
    check paths.nameIndexRoot == "/run/jumpstart/name-index"
    check paths.cgroupRoot == "/sys/fs/cgroup/jumpstart/cores"
    check paths.socketPath == "/run/jumpstart.sock"

  test "user paths use supplied password database home and fallback runtime":
    putEnv("HOME", "/wrong-home")
    let paths = pathsFor(cmUser, 1000, "/passwd/home")
    check paths.coreRoots == @["/usr/lib/jumpstart/cores", "/passwd/home/.local/lib/jumpstart/cores"]
    check paths.configRoot == "/passwd/home/.config/jumpstart"
    check paths.enabledRoot == "/passwd/home/.config/jumpstart/cores/enabled"
    check paths.stateRoot == "/passwd/home/.local/state/jumpstart/cores"
    check paths.runtimeRoot == "/passwd/home/.local/share/jumpstart/runtime/jumpstart/cores"
    check paths.socketPath == "/passwd/home/.local/share/jumpstart/jumpstart.sock"
    check paths.fallbackRuntime

  test "verified runtime and all roots are injectable":
    var roots = defaultCorePathRoots()
    roots.systemCoreRoot = "/fixture/system-cores"
    roots.userCoreRelative = "user-cores"
    roots.userConfigRelative = "config"
    roots.userStateRelative = "state"
    roots.userDataRelative = "data"
    roots.userCgroupRoot = "/fixture/cgroups/users"
    let paths = pathsFor(cmUser, 42, "/home/test", "/fixture/run/user/42", roots)
    check paths.coreRoots == @["/fixture/system-cores", "/home/test/user-cores"]
    check paths.configRoot == "/home/test/config"
    check paths.runtimeRoot == "/fixture/run/user/42/jumpstart/cores"
    check paths.nameIndexRoot == "/fixture/run/user/42/jumpstart/name-index"
    check paths.cgroupRoot == "/fixture/cgroups/users/42/cores"
    check not paths.fallbackRuntime

  test "runtime selection verifies the conventional per-user directory":
    var checkedPath = ""
    var checkedUid = -1
    let accept: RuntimeDirCheck = proc(path: string, uid: int): bool =
      checkedPath = path
      checkedUid = uid
      true
    check selectRuntimeDir(42, "/home/test", runtimeBase = "/fixture/run/user",
      check = accept) == "/fixture/run/user/42"
    check checkedPath == "/fixture/run/user/42"
    check checkedUid == 42
    let reject: RuntimeDirCheck = proc(path: string, uid: int): bool = false
    check selectRuntimeDir(42, "/home/test", check = reject) ==
      "/home/test/.local/share/jumpstart/runtime"

  test "passwd paths select verified runtime automatically":
    let lookup: PasswdHomeLookup = proc(uid: int): string = "/database/home"
    let verify: RuntimeDirCheck = proc(path: string, uid: int): bool =
      path == "/run/user/77" and uid == 77
    let paths = pathsForPasswd(cmUser, 77, homeLookup = lookup,
      runtimeCheck = verify)
    check paths.runtimeRoot == "/run/user/77/jumpstart/cores"
    check not paths.fallbackRuntime

  test "password database home lookup is injectable":
    putEnv("HOME", "/wrong-home")
    var lookedUp = -1
    let lookup: PasswdHomeLookup = proc(uid: int): string =
      lookedUp = uid
      "/database/home"
    let paths = pathsForPasswd(cmUser, 77, roots = defaultCorePathRoots(),
      homeLookup = lookup)
    check lookedUp == 77
    check paths.home == "/database/home"
    check paths.configRoot == "/database/home/.config/jumpstart"

  test "system password path construction never invokes user lookup":
    let lookup: PasswdHomeLookup = proc(uid: int): string =
      raise newException(AssertionDefect, "user password database was read")
    let paths = pathsForPasswd(cmSystem, 0, homeLookup = lookup)
    check paths.mode == cmSystem

  test "invalid path mode inputs fail":
    expect ModeError: discard pathsFor(cmSystem, 1)
    expect ModeError: discard pathsFor(cmUser, 0, "/root")
    expect ModeError: discard pathsFor(cmUser, 1, "relative")
    expect ModeError: discard pathsFor(cmUser, 1, "/home/user", "relative/run")
    expect ModeError: discard pathsFor(cmUser, -1, "/home/user")

import std/[os, strutils]
import posix

proc tmpDir(name: string): string =
  # Short paths: Unix socket paths are limited to ~104 bytes.
  result = "/tmp/js-" & name & "-" & $getCurrentProcessId()
  if dirExists(result): removeDir(result)
  createDir(result)

suite "mode helpers":
  test "users linger is impossible in user mode":
    let user = pathsFor(cmUser, 1000, "/home/alice")
    check user.lingerRoot == ""
    check not user.lingerAvailable
    expect ModeError: requireLinger(user)
    let system = pathsFor(cmSystem, 0)
    check system.lingerAvailable
    requireLinger(system)

  test "the fallback runtime directory is emptied at startup without following links":
    let home = tmpDir("home")
    defer: removeDir(home)
    let uid = int(getuid())
    let paths = pathsFor(cmUser, max(uid, 1), home)
    check paths.fallbackRuntime
    check paths.runtimeDir == home / ".local/share/jumpstart/runtime"
    if uid == 0:
      skip()
    else:
      createDir(paths.runtimeDir / "jumpstart" / "cores" / "old")
      writeFile(paths.runtimeDir / "stale.pid", "1")
      let outside = home / "outside"
      createDir(outside)
      writeFile(outside / "keep", "x")
      createSymlink(outside, paths.runtimeDir / "link")
      check emptyFallbackRuntime(paths)
      var entries = 0
      for _ in walkDir(paths.runtimeDir): inc entries
      check entries == 0
      check fileExists(outside / "keep")
      var st: Stat
      check stat(paths.runtimeDir.cstring, st) == 0 and
        (st.st_mode and Mode(0o777)) == Mode(0o700)
      check not emptyFallbackRuntime(pathsFor(cmUser, uid, home,
                                              validRuntimeDir = "/run/user/" & $uid))

  test "stale sockets are probed: dead ones removed, live ones refused":
    let dir = tmpDir("sock")
    defer: removeDir(dir)
    let path = dir / "j.sock"
    check probeExistingSocket(path) == spMissing
    let live = bindControlSocket(path)
    expect SocketInUseError: discard probeExistingSocket(path)
    expect SocketInUseError: discard bindControlSocket(path)
    discard posix.close(live)          # the daemon died; the file remains
    check probeExistingSocket(path) == spStale
    var st: Stat
    check lstat(path.cstring, st) != 0
    writeFile(path, "not a socket")
    expect ModeError: discard probeExistingSocket(path)

  test "the control socket is 0600 even with a permissive umask, with no staging leftovers":
    let dir = tmpDir("umask")
    defer: removeDir(dir)
    let old = umask(Mode(0))
    defer: discard umask(old)
    let path = dir / "jumpstart.sock"
    let fd = bindControlSocket(path)
    defer: discard posix.close(fd)
    var st: Stat
    check lstat(path.cstring, st) == 0
    check S_ISSOCK(st.st_mode)
    check (st.st_mode and Mode(0o777)) == Mode(0o600)
    var names: seq[string]
    for kind, entry in walkDir(dir, relative = true): names.add entry
    check names == @["jumpstart.sock"]
    check socketAccepts(path)

  test "private directories must be real, owned and 0700":
    let dir = tmpDir("private")
    defer: removeDir(dir)
    let uid = int(getuid())
    ensurePrivateDir(dir / "a" / "b", uid)
    var st: Stat
    check stat((dir / "a" / "b").cstring, st) == 0 and
      (st.st_mode and Mode(0o777)) == Mode(0o700)
    createSymlink(dir / "a", dir / "link")
    expect ModeError: ensurePrivateDir(dir / "link", uid)
    expect ModeError: ensurePrivateDir(dir / "a" / "b", uid + 1)
