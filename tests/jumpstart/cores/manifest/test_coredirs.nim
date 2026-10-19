import std/[os, strutils, unittest]
import posix
import ../../../../jumpstart/cores/daemon/core_host,
  ../../../../jumpstart/cores/manifest/coredirs,
  ../../../../jumpstart/cores/lifecycle/lifecycle_exec
import jumpstartcore/[cgroups, errors]

proc modeOf(path: string): int =
  var st: Stat
  doAssert lstat(path.cstring, st) == 0
  int(st.st_mode and Mode(0o7777))

proc tempRoot(name: string): string =
  result = getTempDir() / ("jumpstart-" & name & "-" & $getCurrentProcessId())
  if dirExists(result): removeDir(result)
  createDir(result)

let me = CoreDirOwner(uid: int(getuid()), gid: int(getgid()))

suite "per-core directories":
  test "runtime directory is fresh, 0700, owned by the account and removed on unload":
    let root = tempRoot("rundir")
    defer: removeDir(root)
    createDir(root / "run")
    let dirs = coreDirectories(root / "state", root / "run", "demo")
    discard umask(Mode(0o022))
    createDir(dirs.runtimeDir)
    writeFile(dirs.runtimeDir / "leftover", "x")
    createRuntimeDir(dirs, me, "demo")
    check modeOf(dirs.runtimeDir) == 0o700
    check not fileExists(dirs.runtimeDir / "leftover")
    var st: Stat
    check stat(dirs.runtimeDir.cstring, st) == 0 and st.st_uid == Uid(me.uid)
    # Removal never follows a symlink planted inside.
    createDir(root / "victim")
    writeFile(root / "victim" / "keep", "x")
    createSymlink(root / "victim", dirs.runtimeDir / "link")
    removeRuntimeDir(dirs, "demo")
    check not dirExists(dirs.runtimeDir)
    check fileExists(root / "victim" / "keep")

  test "removal never follows a symlink swapped into a tree, however deep":
    let root = tempRoot("rmlink")
    defer: removeDir(root)
    createDir(root / "run")
    createDir(root / "victim" / "sub")
    writeFile(root / "victim" / "keep", "x")
    writeFile(root / "victim" / "sub" / "keep2", "x")
    let dirs = coreDirectories(root / "state", root / "run", "demo")
    createRuntimeDir(dirs, me, "demo")
    createDir(dirs.runtimeDir / "a" / "b")
    writeFile(dirs.runtimeDir / "a" / "b" / "file", "x")
    createSymlink(root / "victim", dirs.runtimeDir / "a" / "b" / "dirlink")
    createSymlink(root / "victim" / "keep", dirs.runtimeDir / "filelink")
    createSymlink(root / "nowhere", dirs.runtimeDir / "dangling")
    removeRuntimeDir(dirs, "demo")
    check not dirExists(dirs.runtimeDir)
    check fileExists(root / "victim" / "keep")
    check fileExists(root / "victim" / "sub" / "keep2")
    # A runtime directory that is itself a symlink: the link goes, not its target.
    createSymlink(root / "victim", dirs.runtimeDir)
    removeRuntimeDir(dirs, "demo")
    check not symlinkExists(dirs.runtimeDir)
    check fileExists(root / "victim" / "keep")

  test "ensureDaemonDir tolerates a permission fix that cannot be made":
    let root = tempRoot("ensuredir")
    defer: removeDir(root)
    var warnings: seq[string]
    let warn = proc(message: string) = warnings.add message
    # Missing: created, private when asked.
    ensureDaemonDir(root / "new", private = true, warn)
    check modeOf(root / "new") == 0o700
    # Existing and already private: nothing to fix, nothing to report.
    ensureDaemonDir(root / "new", private = true, warn)
    check warnings.len == 0
    # Existing, not ours to chmod (EPERM for a regular user): reported, not raised.
    if getuid() != 0 and dirExists("/usr"):
      ensureDaemonDir("/usr", private = true, warn)
      check warnings.len == 1
      check "/usr" in warnings[0]
    # Creating a missing directory that cannot be created still fails.
    writeFile(root / "file", "x")
    expect CatchableError: ensureDaemonDir(root / "file" / "child", private = true, warn)

  test "state directory only after filesystems are ready, never below a pending mount":
    let root = tempRoot("statedir")
    defer: removeDir(root)
    let dirs = coreDirectories(root / "var" / "lib" / "jumpstart" / "cores",
                               root / "run", "demo")
    check not ensureStateDir(dirs, me, "demo", filesystemsReady = false)
    check not dirExists(dirs.stateDir)
    try:
      discard ensureStateDir(dirs, me, "demo", true, [root / "var"])
      check false
    except CoreError as e:
      check e.code == ecIo
      check "not mounted yet" in e.msg
    check not dirExists(root / "var")
    check ensureStateDir(dirs, me, "demo", true, [root / "other"])
    check modeOf(dirs.stateDir) == 0o700
    check ensureStateDir(dirs, me, "demo", true)

  test "pending fstab mounts are those not in mountinfo":
    let fstab = "# comment\n/dev/sda1 / ext4 defaults 0 1\n" &
      "/dev/sda2 /var ext4 defaults 0 2\n/dev/sda3 none swap sw 0 0\n" &
      "/dev/sdb1 /mnt/backup ext4 noauto 0 0\nserver:/x /srv\\040data nfs rw 0 0\n"
    let mountinfo = "22 1 8:1 / / rw - ext4 /dev/sda1 rw\n"
    check pendingFstabMounts(fstab, mountinfo) == @["/var", "/srv data"]
    check belowPendingMount("/var/lib/jumpstart/cores/x", ["/var"]) == "/var"
    check belowPendingMount("/variable/x", ["/var"]) == ""

suite "core host resource steps":
  proc fakeSystem(): CgroupSystem =
    result.exists = proc(path: string): bool = fileExists(path) or dirExists(path)
    result.isDir = proc(path: string): bool = dirExists(path)
    result.makeDir = proc(path: string) =
      createDir(path)
      writeFile(path / "cgroup.controllers", "cpu\n")
      writeFile(path / "cgroup.events", "populated 0\n")
      for f in ["cgroup.procs", "cgroup.threads", "cgroup.subtree_control", "cgroup.kill"]:
        writeFile(path / f, "")
    result.readFile = proc(path: string): string = readFile(path)
    result.writeFile = proc(path, value: string) = writeFile(path, value)
    result.removeDir = proc(path: string) =
      for kind, child in walkDir(path):
        if kind == pcDir: raise newException(OSError, "EBUSY")
      removeDir(path)
    result.chownPath = proc(path: string; uid, gid: int) = discard
    result.listDirs = proc(path: string): seq[string] =
      for kind, child in walkDir(path, relative = true):
        if kind == pcDir: result.add child
    result.now = proc(): float = 0.0
    result.pause = proc(ms: int) = discard

  test "extensions need cgroups; serviceHandler runs without them":
    let host = newCoreHost(CoreHostConfig(cgroupsAvailable: false,
      cgroupRoot: "/nonexistent/cores", stateRoot: "/s", runtimeRoot: "/r",
      account: proc(core: string): CoreDirOwner = me,
      filesystemsReady: proc(): bool = false,
      pendingMounts: proc(): seq[string] = @[]))
    check host.checkCgroupStep()("serviceHandler").ok
    check host.checkCgroupStep()("demo").error.code == ecCgroup
    check host.createCgroupStep()("serviceHandler").ok
    check host.controlProcs("serviceHandler") == ""

  test "cgroup steps create, report busy, and kill+remove":
    let root = tempRoot("host")
    defer: removeDir(root)
    let cores = root / "jumpstart" / "cores"
    createDir(cores)
    for dir in [root / "jumpstart", cores]:
      writeFile(dir / "cgroup.controllers", "cpu\n")
      writeFile(dir / "cgroup.subtree_control", "")
    let host = newCoreHost(CoreHostConfig(cgroupsAvailable: true,
      cgroupRoot: cores, stateRoot: root / "state", runtimeRoot: root / "run",
      cgroupSystem: fakeSystem(),
      account: proc(core: string): CoreDirOwner = me,
      filesystemsReady: proc(): bool = true,
      pendingMounts: proc(): seq[string] = @[]))
    check host.createCgroupStep()("demo").ok
    check host.controlProcs("demo") == cores / "demo" / "control" / "cgroup.procs"
    check host.unitsPopulated("demo") == (true, false)
    writeFile(cores / "demo" / "units" / "cgroup.events", "populated 1\n")
    check host.unitsPopulated("demo") == (true, true)
    writeFile(cores / "demo" / "units" / "cgroup.events", "populated 0\n")
    check host.killCgroupStep()("demo").ok
    check not dirExists(cores / "demo")
    createDir(root / "run")
    check host.createRuntimeDirStep()("demo").ok
    check dirExists(root / "run" / "demo")
    check host.createStateDirStep()("demo").ok
    check dirExists(root / "state" / "demo")
    check host.removeRuntimeDirStep()("demo").ok
    check not dirExists(root / "run" / "demo")
    check dirExists(root / "state" / "demo")    # survives unload

  test "a cgroup step that fails halfway kills and removes what it created":
    let root = tempRoot("hostpartial")
    defer: removeDir(root)
    let cores = root / "jumpstart" / "cores"
    createDir(cores)
    for dir in [root / "jumpstart", cores]:
      writeFile(dir / "cgroup.controllers", "cpu\n")
      writeFile(dir / "cgroup.subtree_control", "")
    var system = fakeSystem()
    system.chownPath = proc(path: string; uid, gid: int) =
      raise newException(OSError, "EPERM")      # delegation (§15.1 rule 4) fails
    let host = newCoreHost(CoreHostConfig(cgroupsAvailable: true,
      cgroupRoot: cores, stateRoot: root / "state", runtimeRoot: root / "run",
      cgroupSystem: system,
      account: proc(core: string): CoreDirOwner = CoreDirOwner(uid: 4242, gid: 4242),
      filesystemsReady: proc(): bool = true,
      pendingMounts: proc(): seq[string] = @[]))
    let created = host.createCgroupStep()("demo")
    check not created.ok
    check created.error.code == ecCgroup
    # The load procedure does not roll a step back that never completed, so
    # the step itself leaves nothing behind.
    check not dirExists(cores / "demo")
    check not host.hasCgroup("demo")
