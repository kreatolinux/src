## Real cgroup v2 tests (§15.1, §27.7). They need root and a writable cgroup2
## hierarchy at /sys/fs/cgroup (a privileged container with its own cgroup
## namespace) and skip cleanly otherwise. The test process first moves itself
## into a leaf so the namespace root may delegate controllers.
import std/[options, os, strutils, unittest]
import posix
import jumpstartcore/[cgroups, reaper, spawn]

const Mount = "/sys/fs/cgroup"

proc liveAvailable(): bool =
  when not defined(linux): return false
  else:
    if getuid() != 0: return false
    if not fileExists(Mount / "cgroup.controllers"): return false
    try:
      let info = readFile("/proc/self/mountinfo")
      if mountInfoFsType(info, Mount) != "cgroup2": return false
      createDir(Mount / "jstest-self")
      writeFile(Mount / "jstest-self" / "cgroup.procs", $getpid())
      true
    except CatchableError:
      false

proc cgroupOf(pid: int): string =
  selfCgroupPath(readFile("/proc/" & $pid & "/cgroup"))

proc readAll(fd: cint): string =
  var buffer: array[512, char]
  while true:
    let count = posix.read(fd, addr buffer[0], buffer.len)
    if count > 0:
      for i in 0 ..< int(count): result.add buffer[i]
    elif count < 0 and osLastError() == OSErrorCode(EINTR): continue
    else: break
  closeFd(fd)

proc waitExit(r: Reaper; pid: Pid): ChildStatus =
  for _ in 0 .. 1000:
    discard r.drain()
    if r.takeCompleted(pid, result): return
    sleep(5)
  raise newException(IOError, "child was not reaped")

proc noZombieChildren(): bool =
  let self = $getpid()
  for kind, path in walkDir("/proc"):
    let name = lastPathPart(path)
    if not name.allCharsInSet({'0'..'9'}): continue
    try:
      let stat = readFile(path / "stat")
      let fields = stat[stat.rfind(')') + 2 .. ^1].splitWhitespace
      if fields[1] == self and fields[0] == "Z": return false
    except CatchableError: discard
  true

let available = liveAvailable()

suite "live cgroup v2":
  if not available:
    test "live cgroup tests skipped (need root and writable cgroup2)":
      skip()
  else:
    let sys = defaultCgroupSystem()
    let h = cgroupHierarchy(Mount)

    test "core processes start in control/ and unload kills the subtree":
      prepareSystemHierarchy(h, sys)
      let layout = createCoreCgroups(h.cores, "livetest", sys)
      let r = newReaper()
      let child = spawn(ProcessSpec(executable: "/bin/sh",
        arguments: @["-c", "sleep 60 & sleep 60"], workingDirectory: "/",
        environment: buildSystemEnvironment(),
        cgroupProcs: layout.control / "cgroup.procs"), r)
      check cgroupOf(int(child.pid)) == "/jumpstart/cores/livetest/control"
      check cgroupPopulated(layout.core, sys)
      killCore(layout, sys)
      discard waitExit(r, child.pid)
      sleep(50)
      discard r.drain()
      check not dirExists(layout.core)
      check noZombieChildren()
      closeFd(child.stdoutFd); closeFd(child.stderrFd)

    test "a delegated non-root account moves control/ to units/ but not back, and cannot change limits":
      prepareSystemHierarchy(h, sys)
      let layout = createCoreCgroups(h.cores, "delegated", sys)
      delegateCore(layout, 1000, 1000, sys)
      var st: Stat
      check stat((layout.control / "cgroup.procs").cstring, st) == 0 and st.st_uid == 0
      check stat((layout.core / "cgroup.procs").cstring, st) == 0 and st.st_uid == 1000
      check stat((layout.units / "cgroup.subtree_control").cstring, st) == 0 and st.st_uid == 1000
      check stat((layout.core / "cgroup.kill").cstring, st) == 0 and st.st_uid == 0
      let script = """
        sleep 60 & svc=$!
        mkdir "$U/x.unit" && echo mkdir-ok
        echo $svc > "$U/x.unit/cgroup.procs" && echo move-units-ok
        echo $svc > "$C/cgroup.procs" 2>/dev/null && echo move-control-ok || echo move-control-denied
        echo 1000000 > "$K/memory.max" 2>/dev/null && echo limit-ok || echo limit-denied
        echo $(cat /proc/$svc/cgroup)
        kill $svc
      """
      let r = newReaper()
      let child = spawn(ProcessSpec(executable: "/bin/sh",
        arguments: @["-c", script], workingDirectory: "/",
        environment: buildSystemEnvironment(manifest = {"U": layout.units,
          "C": layout.control, "K": layout.core}),
        uid: Uid(1000), gid: Gid(1000), setIdentity: true,
        cgroupProcs: layout.control / "cgroup.procs"), r)
      let output = readAll(child.stdoutFd)
      closeFd(child.stderrFd)
      discard waitExit(r, child.pid)
      check "mkdir-ok" in output
      check "move-units-ok" in output
      check "move-control-denied" in output
      check "limit-denied" in output
      check "0::/jumpstart/cores/delegated/units/x.unit" in output
      killCore(layout, sys)
      check not dirExists(layout.core)

    test "the user daemon leaf is users/UID/daemon and controllers reach its cores":
      prepareSystemHierarchy(h, sys)
      let layout = createUserCgroups(h.users, 1000, sys)
      delegateUser(layout, 1000, 1000, sys)
      let script = """
        cat /proc/self/cgroup
        mkdir "$P/cores" && echo cores-ok
        for c in $(cat "$P/cgroup.controllers"); do echo "+$c" > "$P/cgroup.subtree_control" || exit 3; done
        echo "controllers: $(cat "$P/cores/cgroup.controllers")"
      """
      let r = newReaper()
      let child = spawn(ProcessSpec(executable: "/bin/sh",
        arguments: @["-c", script], workingDirectory: "/",
        environment: buildSystemEnvironment(manifest = {"P": layout.user}),
        uid: Uid(1000), gid: Gid(1000), setIdentity: true,
        cgroupProcs: layout.daemon / "cgroup.procs"), r)
      let output = readAll(child.stdoutFd)
      closeFd(child.stderrFd)
      let status = waitExit(r, child.pid)
      check status.code == 0
      check "0::/jumpstart/users/1000/daemon" in output
      check "cores-ok" in output
      let controllers = readFile(h.users / "cgroup.controllers").strip
      if controllers.len > 0:
        check ("controllers: " & controllers.splitWhitespace[0]) in output
      killUserCgroups(layout, sys)
      check not dirExists(layout.user)

    test "nested unit cgroups: slice chain, escaped names, attribution, subtree kill":
      prepareSystemHierarchy(h, sys)
      let layout = createCoreCgroups(h.cores, "nested", sys)
      let slice = "system.slice.unit"
      let unit = "foo@a\\x2db.service.unit"
      let path = ensureNestedUnitCgroup(layout, [slice, unit], sys)
      check path == layout.units / slice / unit
      # Controllers reached the slice and its child (the unit is a leaf).
      check readFile(layout.units / slice / "cgroup.subtree_control").strip.len > 0 or
        readFile(layout.units / "cgroup.controllers").strip.len == 0
      let r = newReaper()
      let child = spawn(ProcessSpec(executable: "/bin/sh",
        arguments: @["-c", "sleep 60 & sleep 60"], workingDirectory: "/",
        environment: buildSystemEnvironment(),
        cgroupProcs: path / "cgroup.procs"), r)
      let text = readFile("/proc/" & $child.pid & "/cgroup")
      check unitOfPid(layout, text) == some(@[slice, unit])
      check cgroupPopulated(path, sys)
      # A whole slice subtree is killed with one write and removed bottom-up.
      killCgroup(layout.units / slice, sys)
      discard waitExit(r, child.pid)
      closeFd(child.stdoutFd); closeFd(child.stderrFd)
      check not cgroupPopulated(path, sys)
      check removeNestedUnitCgroup(layout, [slice, unit], sys) == 2
      check dirExists(layout.units)
      killCore(layout, sys)
      check not dirExists(layout.core)

    test "passFds and explicitStdio reach the executed program on Linux":
      var fds: array[2, cint]
      check pipe(fds) == 0
      let null = posix.open("/dev/null", O_RDONLY)
      let r = newReaper()
      let child = spawn(ProcessSpec(executable: "/bin/sh",
        arguments: @["-c", "echo via-fd >&1; for n in 0 1 2 3 4 5 6 7 8 9 10 11; do [ -e /proc/$$/fd/$n ] && printf '%s ' $n; done; true"],
        workingDirectory: "/", environment: buildSystemEnvironment(),
        explicitStdio: some([null, fds[1], fds[1]]),
        passFds: @[(source: null, target: cint(9))]), r)
      closeFd(null); closeFd(fds[1])
      let output = readAll(fds[0])
      discard waitExit(r, child.pid)
      check output.startsWith("via-fd\n")
      let open = output.splitLines[1].splitWhitespace
      # 0, 1, 2 (standard) and 9 (passed); nothing else.
      check open == @["0", "1", "2", "9"]
