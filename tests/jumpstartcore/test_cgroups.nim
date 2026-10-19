import std/[os, strutils, unittest]
import jumpstartcore/[cgroups, errors]

proc fixtureSystem(root: string; writes: ref seq[(string, string)]): CgroupSystem =
  result.exists = proc(path: string): bool = fileExists(path) or dirExists(path)
  result.isDir = proc(path: string): bool = dirExists(path)
  result.makeDir = proc(path: string) =
    createDir(path)
    writeFile(path / "cgroup.controllers", "memory cpu io\n")
    for name in ["cgroup.procs", "cgroup.threads", "cgroup.subtree_control"]:
      writeFile(path / name, "")
  result.readFile = proc(path: string): string = readFile(path)
  result.writeFile = proc(path, value: string) =
    writes[].add((path, value))
    writeFile(path, value)
  result.removeDir = proc(path: string) = removeDir(path)
  result.now = proc(): float = 0.0
  result.pause = proc(milliseconds: int) = discard

suite "cgroup v2 layout and validation":
  test "core and unit paths are exact and suffix checked":
    let root = getTempDir() / "jumpstart-cgroup-layout"
    let layout = coreCgroups(root / "cores", "serviceHandler")
    check layout.core == root / "cores" / "serviceHandler"
    check layout.control == layout.core / "control"
    check layout.units == layout.core / "units"
    check validUnitCgroupName("sshd.service.unit")
    check validUnitCgroupName("opaque name.unit")
    for name in ["unit", ".unit", "bad/unit.unit", "bad\\unit"]:
      check not validUnitCgroupName(name)
    expect CgroupError: discard coreCgroups("relative", "core")
    expect CgroupError: discard coreCgroups(root, "bad/name")

  test "unit cgroup names: the §15.1 rule 7 table":
    # Valid: backslash and percent (escaped systemd names), and anything else
    # that is neither `/`, NUL, nor a control character.
    for name in ["foo@a\\x2db.service.unit", "foo%5cbar.unit", "100%25.unit",
                 "a b.unit", "a:b.unit", "\\.unit", "..unit", "...unit",
                 "cgroup.procs.unit", "memory.max.unit", "日本語.service.unit",
                 "x".repeat(255 - 5) & ".unit"]:
      check validUnitCgroupName(name)
    # Invalid: empty stem, wrong or missing suffix, `/`, NUL, controls, > 255.
    for name in ["", ".unit", "unit", "foo.service", "foo.unit.x", "a/b.unit",
                 "a\0b.unit", "a\nb.unit", "a\tb.unit", "a\x7fb.unit",
                 "a\x01.unit", "x".repeat(256 - 5) & ".unit", ".", ".."]:
      check not validUnitCgroupName(name)
    check validUnitCgroupName("x".repeat(250) & ".unit")
    check not validUnitCgroupName("x".repeat(251) & ".unit")
    # Multi-byte stems count bytes, not characters.
    check validUnitCgroupName("é".repeat(125) & ".unit")
    check not validUnitCgroupName("é".repeat(126) & ".unit")
    # The path helpers accept the same names, including a stem with `..` between
    # backslashes (not a path component).
    let layout = coreCgroups(getTempDir() / "jumpstart-cgroup-names" / "cores", "demo")
    check unitCgroupPath(layout.units, "foo@a\\x2db.service.unit") ==
      layout.units / "foo@a\\x2db.service.unit"
    check unitCgroupPath(layout.units, "a\\..\\b.unit") == layout.units / "a\\..\\b.unit"
    expect CgroupError: discard unitCgroupPath(layout.units, "a/b.unit")

  test "serviceHandler's native name function is unchanged":
    check unitCgroupName("sshd") == "sshd.unit"
    expect CgroupError: discard unitCgroupName("a/b")
    expect CgroupError: discard unitCgroupName("")
    expect CgroupError: discard unitCgroupName("a\\b")   # still rejected natively
    expect CgroupError: discard unitCgroupName("x".repeat(251))
    check unitCgroupName("a b@c:d") == "a b@c:d.unit"

  test "controllers and core layout use only injected temporary hierarchy":
    let temp = getTempDir() / "jumpstart-cgroups-test"
    if dirExists(temp): removeDir(temp)
    let jumpstart = temp / "jumpstart"
    let cores = jumpstart / "cores"
    createDir(cores)
    writeFile(jumpstart / "cgroup.controllers", "memory cpu io cpu\n")
    writeFile(jumpstart / "cgroup.subtree_control", "")
    writeFile(cores / "cgroup.controllers", "pids memory\n")
    writeFile(cores / "cgroup.subtree_control", "")
    var writesRef: ref seq[(string, string)]
    new(writesRef)
    let sys = fixtureSystem(temp, writesRef)
    let layout = createCoreCgroups(cores, "example", sys)
    check dirExists(layout.control)
    check dirExists(layout.units)
    check (jumpstart / "cgroup.subtree_control", "+cpu +io +memory") in writesRef[]
    check (cores / "cgroup.subtree_control", "+memory +pids") in writesRef[]
    check createUnitCgroup(layout, "web.unit", sys) == layout.units / "web.unit"
    expect CgroupError: discard createUnitCgroup(layout, "web", sys)
    removeDir(temp)

  test "controller and event input fails closed":
    check controllerNames("memory cpu cpu") == @["cpu", "memory"]
    expect CgroupError: discard controllerNames("cpu +memory")
    check populated("populated 1\nfrozen 0\n")
    check not populated("populated 0\n")
    expect CgroupError: discard populated("frozen 0\n")

# A fake cgroupfs: directories hold interface files that cannot be unlinked,
# and rmdir succeeds only for a directory without child directories (the
# interface files vanish with it), exactly like cgroup2.
proc fakeCgroupfs(log: ref seq[string]; events: ref seq[(string, string)]): CgroupSystem =
  result.exists = proc(path: string): bool = fileExists(path) or dirExists(path)
  result.isDir = proc(path: string): bool = dirExists(path)
  result.makeDir = proc(path: string) =
    createDir(path)
    writeFile(path / "cgroup.controllers", "cpu memory\n")
    writeFile(path / "cgroup.events", "populated 0\nfrozen 0\n")
    for name in ["cgroup.procs", "cgroup.threads", "cgroup.subtree_control",
                 "cgroup.kill", "memory.max"]:
      writeFile(path / name, "")
  result.readFile = proc(path: string): string = readFile(path)
  result.writeFile = proc(path, value: string) =
    log[].add("write " & path & "=" & value)
    if path.endsWith("cgroup.kill"):
      # The kill empties the subtree.
      events[].add((parentDir(path), "killed"))
      for item in walkDirRec(parentDir(path), yieldFilter = {pcFile}):
        if item.endsWith("cgroup.events"): writeFile(item, "populated 0\n")
        if item.endsWith("cgroup.procs"): writeFile(item, "")
    else:
      writeFile(path, value)
  result.removeDir = proc(path: string) =
    for kind, child in walkDir(path):
      if kind == pcDir: raise newException(OSError, "EBUSY: child cgroups exist")
    log[].add("rmdir " & path)
    removeDir(path)
  result.chownPath = proc(path: string; uid, gid: int) =
    log[].add("chown " & path & " " & $uid & ":" & $gid)
  result.listDirs = proc(path: string): seq[string] =
    for kind, child in walkDir(path, relative = true):
      if kind == pcDir: result.add child
  var clock = 0.0
  result.now = proc(): float = clock
  result.pause = proc(milliseconds: int) = clock += float(milliseconds) / 1000.0
  result.signalPid = proc(pid: int; signal: cint) =
    log[].add("signal " & $pid & " " & $signal)

proc freshRoot(name: string): string =
  result = getTempDir() / ("jumpstart-" & name & "-" & $getCurrentProcessId())
  if dirExists(result): removeDir(result)
  createDir(result / "jumpstart" / "cores")
  for dir in [result, result / "jumpstart", result / "jumpstart" / "cores"]:
    writeFile(dir / "cgroup.controllers", "cpu memory\n")
    writeFile(dir / "cgroup.subtree_control", "")

suite "cgroup lifecycle on a fake cgroupfs":
  test "removeCoreCgroups removes unit cgroups bottom-up with rmdir only":
    let root = freshRoot("remove")
    defer: removeDir(root)
    var log: ref seq[string]; new(log)
    var events: ref seq[(string, string)]; new(events)
    let sys = fakeCgroupfs(log, events)
    let layout = createCoreCgroups(root / "jumpstart" / "cores", "demo", sys)
    discard createUnitCgroup(layout, "web.service.unit", sys)
    createDir(layout.units / "web.service.unit" / "nested.unit")
    removeCoreCgroups(layout, sys)
    check not dirExists(layout.core)
    var rmdirs: seq[string]
    for line in log[]:
      if line.startsWith("rmdir "): rmdirs.add line[6 .. ^1]
    check rmdirs == @[layout.control,
      layout.units / "web.service.unit" / "nested.unit",
      layout.units / "web.service.unit", layout.units, layout.core]

  test "removal of a populated cgroup fails instead of deleting files":
    let root = freshRoot("busy")
    defer: removeDir(root)
    var log: ref seq[string]; new(log)
    var events: ref seq[(string, string)]; new(events)
    var sys = fakeCgroupfs(log, events)
    let layout = createCoreCgroups(root / "jumpstart" / "cores", "demo", sys)
    sys.removeDir = proc(path: string) = raise newException(OSError, "EBUSY")
    expect CgroupError: removeCoreCgroups(layout, sys)
    check fileExists(layout.control / "cgroup.procs")

  test "killCore writes cgroup.kill, waits for populated 0, removes the subtree":
    let root = freshRoot("kill")
    defer: removeDir(root)
    var log: ref seq[string]; new(log)
    var events: ref seq[(string, string)]; new(events)
    let sys = fakeCgroupfs(log, events)
    let layout = createCoreCgroups(root / "jumpstart" / "cores", "demo", sys)
    discard createUnitCgroup(layout, "a.unit", sys)
    writeFile(layout.units / "a.unit" / "cgroup.events", "populated 1\n")
    writeFile(layout.core / "cgroup.events", "populated 1\n")
    killCore(layout, sys)
    check events[] == @[(layout.core, "killed")]
    check not dirExists(layout.core)

  test "killCore times out when the cgroup stays populated":
    let root = freshRoot("stuck")
    defer: removeDir(root)
    var log: ref seq[string]; new(log)
    var events: ref seq[(string, string)]; new(events)
    var sys = fakeCgroupfs(log, events)
    let layout = createCoreCgroups(root / "jumpstart" / "cores", "demo", sys)
    sys.writeFile = proc(path, value: string) = discard # kill has no effect
    writeFile(layout.core / "cgroup.events", "populated 1\n")
    expect CgroupError: killCore(layout, sys)
    check dirExists(layout.core)

  test "without cgroup.kill the subtree is frozen, SIGKILLed and thawed":
    let root = freshRoot("freeze")
    defer: removeDir(root)
    var log: ref seq[string]; new(log)
    var events: ref seq[(string, string)]; new(events)
    var sys = fakeCgroupfs(log, events)
    let layout = createCoreCgroups(root / "jumpstart" / "cores", "demo", sys)
    for dir in [layout.core, layout.control, layout.units]:
      removeFile(dir / "cgroup.kill")
      writeFile(dir / "cgroup.freeze", "0")
    writeFile(layout.control / "cgroup.procs", "101\n102\n")
    writeFile(layout.units / "cgroup.procs", "1\n")
    let base = sys.writeFile
    sys.writeFile = proc(path, value: string) =
      base(path, value)
      if path.endsWith("cgroup.freeze") and value == "0":
        writeFile(layout.core / "cgroup.events", "populated 0\n")
    writeFile(layout.core / "cgroup.events", "populated 1\n")
    killCore(layout, sys)
    let freeze = log[].find("write " & layout.core / "cgroup.freeze=1")
    let thaw = log[].find("write " & layout.core / "cgroup.freeze=0")
    check freeze >= 0 and thaw > freeze
    check log[].find("signal 101 9") in freeze .. thaw
    check log[].find("signal 102 9") in freeze .. thaw
    check log[].find("signal 1 9") < 0  # never PID 1
    check not dirExists(layout.core)

  test "delegateCore changes exactly the delegated files":
    let root = freshRoot("delegate")
    defer: removeDir(root)
    var log: ref seq[string]; new(log)
    var events: ref seq[(string, string)]; new(events)
    let sys = fakeCgroupfs(log, events)
    let layout = createCoreCgroups(root / "jumpstart" / "cores", "demo", sys)
    log[].setLen(0)
    delegateCore(layout, 1000, 1000, sys)
    var expected: seq[string]
    for dir in [layout.core, layout.units]:
      expected.add "chown " & dir & " 1000:1000"
      for file in ["cgroup.procs", "cgroup.threads", "cgroup.subtree_control"]:
        expected.add "chown " & dir / file & " 1000:1000"
    check log[] == expected
    expect CgroupError: delegateCore(layout, 0, 0, sys)

  test "user cgroups: users/UID/daemon, delegation of users/UID only, kill":
    let root = freshRoot("users")
    defer: removeDir(root)
    var log: ref seq[string]; new(log)
    var events: ref seq[(string, string)]; new(events)
    let sys = fakeCgroupfs(log, events)
    let h = cgroupHierarchy(root)
    prepareSystemHierarchy(h, sys)
    check dirExists(h.users) and dirExists(h.cores)
    check readFile(h.jumpstart / "cgroup.subtree_control") == "+cpu +memory"
    check readFile(h.users / "cgroup.subtree_control") == "+cpu +memory"
    let layout = createUserCgroups(h.users, 1000, sys)
    check layout.daemon == h.users / "1000" / "daemon"
    check layout.cores == h.users / "1000" / "cores"
    log[].setLen(0)
    delegateUser(layout, 1000, 100, sys)
    check log[] == @["chown " & layout.user & " 1000:100",
      "chown " & layout.user / "cgroup.procs" & " 1000:100",
      "chown " & layout.user / "cgroup.threads" & " 1000:100",
      "chown " & layout.user / "cgroup.subtree_control" & " 1000:100"]
    # The user daemon creates users/UID/cores itself in its delegated subtree.
    let core = createCoreCgroups(layout.cores, "demo", sys)
    check dirExists(core.control)
    killUserCgroups(layout, sys)
    check not dirExists(layout.user)

  test "native unit cgroups are named UNIT.unit and killed with their tree":
    let root = freshRoot("native")
    defer: removeDir(root)
    var log: ref seq[string]; new(log)
    var events: ref seq[(string, string)]; new(events)
    let sys = fakeCgroupfs(log, events)
    let layout = createCoreCgroups(root / "jumpstart" / "cores", "serviceHandler", sys)
    check unitCgroupName("sshd") == "sshd.unit"
    expect CgroupError: discard unitCgroupName("a/b")
    let path = ensureUnitCgroup(layout, unitCgroupName("sshd"), sys)
    check ensureUnitCgroup(layout, unitCgroupName("sshd"), sys) == path
    check cgroupPopulated(path, sys) == false
    writeFile(path / "cgroup.events", "populated 1\n")
    check cgroupPopulated(path, sys)
    killUnitCgroup(path, sys)
    check not dirExists(path)
    check dirExists(layout.units)

  test "mount table, own cgroup and delegation detection":
    let info = "22 1 0:21 / /sys/fs/cgroup rw - tmpfs tmpfs rw\n" &
               "23 22 0:22 / /sys/fs/cgroup rw - cgroup2 cgroup2 rw\n"
    check mountInfoFsType(info, "/sys/fs/cgroup") == "cgroup2"
    check selfCgroupPath("0::/jumpstart/users/1000/daemon\n") == "/jumpstart/users/1000/daemon"
    let root = freshRoot("detect")
    defer: removeDir(root)
    var log: ref seq[string]; new(log)
    var events: ref seq[(string, string)]; new(events)
    let sys = fakeCgroupfs(log, events)
    let h = cgroupHierarchy(root)
    prepareSystemHierarchy(h, sys)
    discard createUserCgroups(h.users, 1000, sys)
    check userDelegationAvailable(root, 1000, "0::/jumpstart/users/1000/daemon\n", sys)
    check not userDelegationAvailable(root, 1000, "0::/user.slice\n", sys)
    check not userDelegationAvailable(root, 1001, "0::/jumpstart/users/1001/daemon\n", sys)
    try:
      requireCgroups(false, "demo")
      check false
    except CoreError as e:
      check e.code == ecCgroup

  test "ensureCgroupV2 fails with E_CGROUP instead of tolerating":
    let dir = getTempDir() / ("jumpstart-cg2-" & $getCurrentProcessId())
    createDir(dir)
    defer: removeDir(dir)
    writeFile(dir / "mountinfo", "30 1 0:25 / " & dir & " rw - cgroup cgroup rw,cpu\n")
    writeFile(dir / "filesystems", "nodev\tcgroup\n")
    try:
      ensureCgroupV2(dir, dir / "mountinfo", dir / "filesystems")
      check false
    except CoreError as e:
      check e.code == ecCgroup
