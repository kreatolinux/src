## Enabled-state storage (jumpstart-cores §§9, 21.14, 27.5).
import std/[algorithm, os, posix, sequtils, strutils, tempfiles, unittest]
import ../../../../jumpstart/cores/manifest/discovery, ../../../../jumpstart/cores/lifecycle/state
import jumpstartcore/errors

proc flock(fd: cint; operation: cint): cint {.importc, header: "<sys/file.h>".}

let me = getuid()

proc privateDir(path: string) =
  createDir(path)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})

proc newBase(prefix: string): string =
  ## Temporary state lives under the system temp dir (§27), never in $HOME.
  result = createTempDir(prefix, "", getTempDir())
  privateDir(result)

proc pathsIn(dir: string): StatePaths =
  StatePaths(enabledDir: dir / "enabled", lockFile: dir / ".lock", trustedUid: me)

proc listing(dir: string): seq[string] =
  for kind, path in walkDir(dir, relative = true): result.add(path)
  result.sort(system.cmp[string])

proc marker(dir, name: string) =
  writeFile(dir / name, "")
  setFilePermissions(dir / name, {fpUserRead, fpUserWrite})

proc stateCode(body: proc()): CoreErrorCode =
  try: body()
  except StateError as e: return e.code
  raise newException(AssertionDefect, "state change did not fail")

proc found(cores: varargs[(string, seq[string])]): DiscoveryResult =
  result.cores.add DiscoveredCore(name: "serviceHandler")
  for (name, targets) in cores:
    result.cores.add DiscoveredCore(name: name, delegationTargets: targets)

proc noMode(path: string): bool =
  var st: Stat
  doAssert lstat(path.cstring, st) == 0
  (st.st_mode and Mode(0o022)) == 0

suite "state: uninitialized and materialization":
  test "absent state yields {serviceHandler} without creating anything":
    let base = newBase("jump-state-")
    defer: removeDir(base)
    let s = readEnabledState(pathsIn(base))
    check not s.initialized
    check s.enabled == @["serviceHandler"]
    # A missing parent (for example /etc/jumpstart/cores) is also uninitialized.
    let deep = pathsIn(base / "etc" / "jumpstart" / "cores")
    check readEnabledState(deep).enabled == @["serviceHandler"]
    check listing(base).len == 0

  test "the first change creates parents and materializes atomically":
    let base = newBase("jump-state-")
    defer: removeDir(base)
    let dir = base / "etc" / "jumpstart" / "cores"
    let paths = pathsIn(dir)
    enableCore(paths, "systemd", found(("systemd", newSeq[string]())))
    let s = readEnabledState(paths)
    check s.initialized
    check s.enabled == @["serviceHandler", "systemd"]
    check listing(dir) == @[".lock", "enabled"]
    check listing(paths.enabledDir) == @["serviceHandler", "systemd"]
    for path in [base / "etc", base / "etc" / "jumpstart", dir, paths.enabledDir, paths.lockFile]:
      check noMode(path)

  test "an empty enabled directory is invalid, never a request for defaults":
    let base = newBase("jump-state-")
    defer: removeDir(base)
    privateDir(base / "enabled")
    check stateCode(proc() = discard readEnabledState(pathsIn(base))) == ecState
    check stateCode(proc() = enableCore(pathsIn(base), "x")) == ecState

suite "state: enable and disable":
  test "enable and disable are idempotent and write nothing when unchanged":
    let base = newBase("jump-state-")
    defer: removeDir(base)
    let dir = base / "cores"
    let paths = pathsIn(dir)
    let cores = found(("systemd", newSeq[string]()))
    enableCore(paths, "serviceHandler", cores)
    disableCore(paths, "systemd", cores)
    check not dirExists(dir)  # uninitialized and untouched
    enableCore(paths, "systemd", cores)
    var before: Stat
    check lstat(cstring(paths.enabledDir / "systemd"), before) == 0
    enableCore(paths, "systemd", cores)
    var after: Stat
    check lstat(cstring(paths.enabledDir / "systemd"), after) == 0
    check before.st_ino == after.st_ino
    disableCore(paths, "serviceHandler", cores)
    disableCore(paths, "serviceHandler", cores)
    check readEnabledState(paths).enabled == @["systemd"]
    check listing(paths.enabledDir) == @["systemd"]

  test "undiscovered, invalid, and badly named cores cannot be enabled":
    let base = newBase("jump-state-")
    defer: removeDir(base)
    let paths = pathsIn(base)
    var cores = found()
    cores.rejected.add RejectedCore(name: "broken", code: E_MANIFEST, reason: "bad manifest")
    check stateCode(proc() = enableCore(paths, "missing", cores)) == ecNotFound
    check stateCode(proc() = enableCore(paths, "broken", cores)) == ecManifest
    check stateCode(proc() = enableCore(paths, "all", cores)) == ecName
    check stateCode(proc() = enableCore(paths, "../x", cores)) == ecName
    check stateCode(proc() = disableCore(paths, "none", cores)) == ecName
    check listing(base).len == 0

  test "the last enabled core cannot be disabled":
    let base = newBase("jump-state-")
    defer: removeDir(base)
    let paths = pathsIn(base)
    check stateCode(proc() = disableCore(paths, "serviceHandler", found())) == ecState
    check not dirExists(paths.enabledDir)
    enableCore(paths, "solo", found(("solo", newSeq[string]())))
    disableCore(paths, "serviceHandler", found(("solo", newSeq[string]())))
    check stateCode(proc() = disableCore(paths, "solo", found(("solo", newSeq[string]())))) == ecState
    check readEnabledState(paths).enabled == @["solo"]

  test "delegation targets must be enabled and cannot be disabled":
    let base = newBase("jump-state-")
    defer: removeDir(base)
    let paths = pathsIn(base)
    let cores = found(("front", @["back"]), ("back", newSeq[string]()), ("other", newSeq[string]()))
    check stateCode(proc() = enableCore(paths, "front", cores)) == ecDelegation
    check not dirExists(paths.enabledDir)
    enableCore(paths, "back", cores)
    enableCore(paths, "front", cores)
    try:
      disableCore(paths, "back", cores)
      check false
    except StateError as e:
      check e.code == ecDelegation
      check e.core == "back"
      check "front" in e.message  # the error names the dependent core
    check readEnabledState(paths).enabled == @["back", "front", "serviceHandler"]
    disableCore(paths, "front", cores)
    disableCore(paths, "back", cores)
    check readEnabledState(paths).enabled == @["serviceHandler"]

  test "dry runs raise what the real change raises and write nothing (§21.14)":
    let base = newBase("jump-state-")
    defer: removeDir(base)
    let paths = pathsIn(base)
    let cores = found(("front", @["back"]), ("back", newSeq[string]()))
    check stateCode(proc() = checkEnableCore(paths, "front", cores)) == ecDelegation
    check stateCode(proc() = checkDisableCore(paths, "serviceHandler", cores)) == ecState
    check stateCode(proc() = checkEnableCore(paths, "ghost", cores)) == ecNotFound
    checkEnableCore(paths, "back", cores)
    checkDisableCore(paths, "back", cores)   # not enabled: succeeds without changes
    check not dirExists(paths.enabledDir)
    check not fileExists(paths.lockFile)
    enableCore(paths, "back", cores)
    enableCore(paths, "front", cores)
    check stateCode(proc() = checkDisableCore(paths, "back", cores)) == ecDelegation
    checkDisableCore(paths, "front", cores)
    check readEnabledState(paths).enabled == @["back", "front", "serviceHandler"]

  test "targets must be discovered; existing breakage does not block others":
    let base = newBase("jump-state-")
    defer: removeDir(base)
    let paths = pathsIn(base)
    let cores = found(("front", @["gone"]), ("other", newSeq[string]()))
    check stateCode(proc() = enableCore(paths, "front", cores)) == ecDelegation
    enableCore(paths, "front")  # low-level form: no policy
    enableCore(paths, "other", cores)
    disableCore(paths, "other", cores)
    check readEnabledState(paths).enabled == @["front", "serviceHandler"]

  test "the legacy invariant callback runs before publication":
    let base = newBase("jump-state-")
    defer: removeDir(base)
    let paths = pathsIn(base)
    proc reject(names: seq[string]) = raise newException(ValueError, "refused")
    expect ValueError: enableCore(paths, "delegate", reject)
    check not dirExists(paths.enabledDir)

suite "state: validation":
  test "malformed, non-empty, directory, and symlinked markers are rejected":
    for kind in ["badname", "nonempty", "directory", "symlink", "badtemp"]:
      let base = newBase("jump-state-")
      defer: removeDir(base)
      let enabled = base / "enabled"; privateDir(enabled)
      marker(enabled, "serviceHandler")
      case kind
      of "badname": marker(enabled, "bad.marker")
      of "nonempty": writeFile(enabled / "x", "1")
      of "directory": privateDir(enabled / "x")
      of "symlink": createSymlink(enabled / "serviceHandler", enabled / "x")
      of "badtemp": writeFile(enabled / ".marker-1-2", "data")
      check stateCode(proc() = discard readEnabledState(pathsIn(base))) == ecState

  test "ownership and mode violations are E_PERMISSION":
    let base = newBase("jump-state-")
    defer: removeDir(base)
    let paths = pathsIn(base)
    enableCore(paths, "x")
    setFilePermissions(paths.enabledDir, {fpUserRead, fpUserWrite, fpUserExec, fpGroupWrite})
    check stateCode(proc() = discard readEnabledState(paths)) == ecPermission
    privateDir(paths.enabledDir)
    setFilePermissions(paths.enabledDir / "x", {fpUserRead, fpUserWrite, fpOthersWrite})
    check stateCode(proc() = discard readEnabledState(paths)) == ecPermission
    setFilePermissions(paths.enabledDir / "x", {fpUserRead, fpUserWrite})
    setFilePermissions(base, {fpUserRead, fpUserWrite, fpUserExec, fpGroupWrite})
    check stateCode(proc() = discard readEnabledState(paths)) == ecPermission
    privateDir(base)
    if me != Uid(0):
      var foreign = paths
      foreign.trustedUid = Uid(4242)
      check stateCode(proc() = discard readEnabledState(foreign)) == ecPermission

  test "trusted per-core directories are checked":
    let base = newBase("jump-state-")
    defer: removeDir(base)
    checkTrustedDirectory(base / "absent", me)
    expect OSError: checkTrustedDirectory(base / "absent", me, required = true)
    privateDir(base / "cores")
    checkTrustedDirectory(base / "cores", me)
    setFilePermissions(base / "cores", {fpUserRead, fpUserWrite, fpUserExec, fpOthersWrite})
    check stateCode(proc() = checkTrustedDirectory(base / "cores", me)) == ecPermission
    createSymlink(base / "cores", base / "link")
    check stateCode(proc() = checkTrustedDirectory(base / "link", me)) == ecPermission
    if me != Uid(0):
      privateDir(base / "cores")
      check stateCode(proc() = checkTrustedDirectory(base / "cores", Uid(4242))) == ecPermission

suite "state: crash safety and locking":
  test "interrupted writers leave the old state and are cleaned up":
    let base = newBase("jump-state-")
    defer: removeDir(base)
    let paths = pathsIn(base)
    # Crash during materialization: the sibling never got renamed.
    privateDir(base / ".enabled-99999-0")
    marker(base / ".enabled-99999-0", "serviceHandler")
    check not readEnabledState(paths).initialized
    enableCore(paths, "a")
    check not dirExists(base / ".enabled-99999-0")
    # Crash during enable: the temporary never got renamed.
    marker(paths.enabledDir, ".marker-99999-3")
    check readEnabledState(paths).enabled == @["a", "serviceHandler"]
    enableCore(paths, "b")
    check listing(paths.enabledDir) == @["a", "b", "serviceHandler"]

  test "an injected write failure leaves old or new state intact":
    if me == Uid(0):
      skip()  # root bypasses directory permissions
    else:
      let base = newBase("jump-state-")
      defer:
        privateDir(base)
        if dirExists(base / "enabled"): privateDir(base / "enabled")
        removeDir(base)
      let paths = pathsIn(base)
      discard posix.close(posix.open(cstring(paths.lockFile), O_CREAT or O_WRONLY, Mode(0o600)))
      setFilePermissions(base, {fpUserRead, fpUserExec})
      expect OSError: enableCore(paths, "a")
      check readEnabledState(paths) == EnabledState(initialized: false, enabled: @["serviceHandler"])
      privateDir(base)
      enableCore(paths, "a")
      setFilePermissions(paths.enabledDir, {fpUserRead, fpUserExec})
      expect OSError: enableCore(paths, "b")
      expect OSError: disableCore(paths, "a")
      check readEnabledState(paths).enabled == @["a", "serviceHandler"]
      privateDir(paths.enabledDir)
      check listing(paths.enabledDir) == @["a", "serviceHandler"]

  test "state changes wait for the lock":
    let base = newBase("jump-state-")
    defer: removeDir(base)
    let paths = pathsIn(base)
    let fd = posix.open(cstring(paths.lockFile), O_CREAT or O_RDWR, Mode(0o600))
    check fd >= 0
    check flock(fd, 2) == 0
    let child = fork()
    if child == 0:
      try:
        enableCore(paths, "waited")
        quit(0)
      except CatchableError: quit(1)
    sleep(300)
    check not dirExists(paths.enabledDir)  # blocked behind our lock
    check flock(fd, 8) == 0
    discard posix.close(fd)
    var status: cint
    check waitpid(child, status, 0) == child
    check WIFEXITED(status) and WEXITSTATUS(status) == 0
    check readEnabledState(paths).enabled == @["serviceHandler", "waited"]

  test "concurrent invocations are serialized":
    let base = newBase("jump-state-")
    defer: removeDir(base)
    let paths = pathsIn(base)
    var children: seq[Pid]
    let wanted = toSeq(0 ..< 8).mapIt("core" & $it)
    for name in wanted:
      let child = fork()
      if child == 0:
        try:
          enableCore(paths, name)
          quit(0)
        except CatchableError: quit(1)
      children.add child
    for child in children:
      var status: cint
      check waitpid(child, status, 0) == child
      check WIFEXITED(status) and WEXITSTATUS(status) == 0
    check readEnabledState(paths).enabled == (wanted & @["serviceHandler"]).sorted(system.cmp[string])
    check listing(base) == @[".lock", "enabled"]
