## Nested unit cgroups and process attribution (§15.1 rule 7, §26.1) on a fake
## cgroupfs: directories get interface files, and rmdir succeeds only for a
## directory without child directories, like cgroup2.
import std/[options, os, strutils, unittest]
import jumpstartcore/cgroups

type Log = ref seq[string]

proc newLog(): Log = new(result)

proc fake(log: Log): CgroupSystem =
  result.exists = proc(path: string): bool = fileExists(path) or dirExists(path)
  result.isDir = proc(path: string): bool = dirExists(path)
  result.makeDir = proc(path: string) =
    log[].add "mkdir " & path
    createDir(path)
    writeFile(path / "cgroup.controllers", "cpu memory pids\n")
    writeFile(path / "cgroup.events", "populated 0\n")
    for name in ["cgroup.procs", "cgroup.threads", "cgroup.subtree_control",
                 "cgroup.kill"]:
      writeFile(path / name, "")
  result.readFile = proc(path: string): string = readFile(path)
  result.writeFile = proc(path, value: string) =
    log[].add "write " & path & "=" & value
    if path.endsWith("cgroup.kill"):
      for item in walkDirRec(parentDir(path), yieldFilter = {pcFile}):
        if item.endsWith("cgroup.events"): writeFile(item, "populated 0\n")
        if item.endsWith("cgroup.procs"): writeFile(item, "")
    else:
      writeFile(path, value)
  result.removeDir = proc(path: string) =
    for kind, _ in walkDir(path):
      if kind == pcDir: raise newException(OSError, "EBUSY: child cgroups exist")
    if readFile(path / "cgroup.procs").len != 0:
      raise newException(OSError, "EBUSY: processes")
    log[].add "rmdir " & path
    removeDir(path)
  result.chownPath = proc(path: string; uid, gid: int) =
    log[].add "chown " & path & " " & $uid & ":" & $gid
  result.listDirs = proc(path: string): seq[string] =
    for kind, child in walkDir(path, relative = true):
      if kind == pcDir: result.add child
  var clock = 0.0
  result.now = proc(): float = clock
  result.pause = proc(milliseconds: int) = clock += float(milliseconds) / 1000.0
  result.signalPid = proc(pid: int; signal: cint) = discard

proc freshRoot(name: string): string =
  result = getTempDir() / ("jumpstart-nested-" & name & "-" & $getCurrentProcessId())
  if dirExists(result): removeDir(result)
  createDir(result / "jumpstart" / "cores")
  for dir in [result, result / "jumpstart", result / "jumpstart" / "cores"]:
    writeFile(dir / "cgroup.controllers", "cpu memory pids\n")
    writeFile(dir / "cgroup.subtree_control", "")

const
  Slice = "system.slice.unit"
  Inner = "foo.slice.unit"
  Escaped = "foo@a\\x2db.service.unit"

suite "nested unit cgroups":
  test "the chain is created below units/ with controllers in each slice":
    let root = freshRoot("create"); defer: removeDir(root)
    let log = newLog(); let sys = fake(log)
    let layout = createCoreCgroups(root / "jumpstart" / "cores", "systemd", sys)
    log[].setLen(0)
    let path = ensureNestedUnitCgroup(layout, [Slice, Inner, Escaped], sys)
    check path == layout.units / Slice / Inner / Escaped
    check dirExists(path)
    check log[] == @[
      "mkdir " & layout.units / Slice,
      "write " & layout.units / Slice / "cgroup.subtree_control=+cpu +memory +pids",
      "mkdir " & layout.units / Slice / Inner,
      "write " & layout.units / Slice / Inner / "cgroup.subtree_control=+cpu +memory +pids",
      "mkdir " & path]
    # Reusing is idempotent and never chowns.
    check ensureNestedUnitCgroup(layout, [Slice, Inner, Escaped], sys) == path
    for line in log[]: check not line.startsWith("chown ")
    # The last component is a slice only on request.
    let slicePath = ensureNestedUnitCgroup(layout, [Slice, "bar.slice.unit"], sys,
      enableLast = true)
    check "write " & slicePath / "cgroup.subtree_control=+cpu +memory +pids" in log[]
    check readFile(path / "cgroup.subtree_control") == ""

  test "a single component is a unit directly in units/ (the root slice)":
    let root = freshRoot("single"); defer: removeDir(root)
    let log = newLog(); let sys = fake(log)
    let layout = createCoreCgroups(root / "jumpstart" / "cores", "systemd", sys)
    check ensureNestedUnitCgroup(layout, ["generators.unit"], sys) ==
      layout.units / "generators.unit"

  test "invalid chains fail before anything is created":
    let root = freshRoot("invalid"); defer: removeDir(root)
    let log = newLog(); let sys = fake(log)
    let layout = createCoreCgroups(root / "jumpstart" / "cores", "systemd", sys)
    log[].setLen(0)
    expect CgroupError: discard ensureNestedUnitCgroup(layout, [], sys)
    expect CgroupError: discard ensureNestedUnitCgroup(layout, [Slice, "bad"], sys)
    expect CgroupError: discard ensureNestedUnitCgroup(layout, [Slice, "a/b.unit"], sys)
    expect CgroupError: discard ensureNestedUnitCgroup(layout, ["..", Slice], sys)
    var deep: seq[string]
    for i in 0 .. MaxNestedUnitDepth: deep.add "s" & $i & ".unit"
    expect CgroupError: discard ensureNestedUnitCgroup(layout, deep, sys)
    check log[].len == 0
    check not dirExists(layout.units / Slice)

  test "removal is rmdir-only, bottom-up, and stops at the first busy ancestor":
    let root = freshRoot("remove"); defer: removeDir(root)
    let log = newLog(); let sys = fake(log)
    let layout = createCoreCgroups(root / "jumpstart" / "cores", "systemd", sys)
    discard ensureNestedUnitCgroup(layout, [Slice, Inner, "a.service.unit"], sys)
    discard ensureNestedUnitCgroup(layout, [Slice, Inner, "b.service.unit"], sys)
    log[].setLen(0)
    check removeNestedUnitCgroup(layout, [Slice, Inner, "a.service.unit"], sys) == 1
    check log[] == @["rmdir " & layout.units / Slice / Inner / "a.service.unit"]
    check dirExists(layout.units / Slice / Inner)
    log[].setLen(0)
    check removeNestedUnitCgroup(layout, [Slice, Inner, "b.service.unit"], sys) == 3
    check log[] == @[
      "rmdir " & layout.units / Slice / Inner / "b.service.unit",
      "rmdir " & layout.units / Slice / Inner,
      "rmdir " & layout.units / Slice]
    check dirExists(layout.units)
    # Missing components are skipped; a second removal removes nothing.
    check removeNestedUnitCgroup(layout, [Slice, Inner, "b.service.unit"], sys) == 0

  test "a populated or non-empty last component raises, a busy ancestor does not":
    let root = freshRoot("busy"); defer: removeDir(root)
    let log = newLog(); let sys = fake(log)
    let layout = createCoreCgroups(root / "jumpstart" / "cores", "systemd", sys)
    let leaf = ensureNestedUnitCgroup(layout, [Slice, "a.service.unit"], sys)
    writeFile(leaf / "cgroup.procs", "42\n")
    expect CgroupError: discard removeNestedUnitCgroup(layout, [Slice, "a.service.unit"], sys)
    check dirExists(leaf)
    writeFile(leaf / "cgroup.procs", "")
    discard ensureNestedUnitCgroup(layout, [Slice, "b.service.unit"], sys)
    check removeNestedUnitCgroup(layout, [Slice, "a.service.unit"], sys) == 1
    check dirExists(layout.units / Slice)  # b.service.unit is still there

  test "a whole subtree is killed and removed with the existing helpers":
    let root = freshRoot("subtree"); defer: removeDir(root)
    let log = newLog(); let sys = fake(log)
    let layout = createCoreCgroups(root / "jumpstart" / "cores", "systemd", sys)
    let a = ensureNestedUnitCgroup(layout, [Slice, Inner, "a.service.unit"], sys)
    writeFile(a / "cgroup.events", "populated 1\n")
    writeFile(a / "cgroup.procs", "7\n")
    let slice = layout.units / Slice
    killCgroup(slice, sys)
    check "write " & slice / "cgroup.kill=1" in log[]
    check not cgroupPopulated(a, sys)
    removeCgroupTree(slice, sys)
    check not dirExists(slice)
    check dirExists(layout.units)

  test "unitOfPid maps /proc/PID/cgroup to the component chain":
    let layout = coreCgroups("/sys/fs/cgroup/jumpstart/cores", "systemd")
    let base = "/jumpstart/cores/systemd/units/"
    proc text(path: string): string = "0::" & path & "\n"
    check unitOfPid(layout, text(base & Slice & "/" & Escaped)) ==
      some(@[Slice, Escaped])
    check unitOfPid(layout, text(base & "generators.unit")) == some(@["generators.unit"])
    # Sub-cgroups of a delegated service belong to the service; a sub-cgroup
    # cannot name another unit.
    check unitOfPid(layout, text(base & Slice & "/svc.service.unit/payload/x.service.unit")) ==
      some(@[Slice, "svc.service.unit"])
    # Not below units/, in units/ itself, in control/, another core, no v2 line.
    check unitOfPid(layout, text("/jumpstart/cores/systemd/control")).isNone
    check unitOfPid(layout, text("/jumpstart/cores/systemd/units")).isNone
    check unitOfPid(layout, text("/jumpstart/cores/other/units/" & Slice)).isNone
    check unitOfPid(layout, text("/system.slice/x.unit")).isNone
    check unitOfPid(layout, "1:name=systemd:/x\n").isNone
    check unitOfPid(layout, "").isNone
    check unitOfPid(layout, text(base & "plain/x.unit")).isNone
    # A cgroup namespace root below /sys/fs/cgroup shortens the prefix.
    check unitOfPid(layout, text("/cores/systemd/units/" & Slice)) == some(@[Slice])
    check unitOfPid(layout, text("/other/cores/systemd/units/" & Slice)).isNone
    # User mode layout.
    let user = coreCgroups("/sys/fs/cgroup/jumpstart/users/1000/cores", "systemd")
    check unitOfPid(user, text("/jumpstart/users/1000/cores/systemd/units/app.slice.unit/a.service.unit")) ==
      some(@["app.slice.unit", "a.service.unit"])
    check unitOfPid(user, text("/jumpstart/users/1001/cores/systemd/units/app.slice.unit")).isNone

  test "delegateDir is exported for delegated unit directories":
    let root = freshRoot("delegate"); defer: removeDir(root)
    let log = newLog(); let sys = fake(log)
    let layout = createCoreCgroups(root / "jumpstart" / "cores", "systemd", sys)
    let dir = ensureNestedUnitCgroup(layout, [Slice, "d.service.unit"], sys)
    log[].setLen(0)
    delegateDir(dir, 1000, 100, sys)
    check log[] == @["chown " & dir & " 1000:100",
      "chown " & dir / "cgroup.procs" & " 1000:100",
      "chown " & dir / "cgroup.threads" & " 1000:100",
      "chown " & dir / "cgroup.subtree_control" & " 1000:100"]
