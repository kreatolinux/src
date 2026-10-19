import std/[os, strutils, unittest]
import posix
import jumpstartcore/[reaper, spawn]

proc waitFor(r: Reaper; done: proc(): bool): bool =
  for _ in 0 .. 1000:
    if r.sigChldPending: discard r.drainWakeup() else: discard r.drain()
    if done(): return true
    sleep(5)
  false

proc zombieChildren(): int =
  when defined(linux):
    let self = $getpid()
    for kind, path in walkDir("/proc"):
      let name = lastPathPart(path)
      if not name.allCharsInSet({'0'..'9'}): continue
      try:
        let stat = readFile(path / "stat")
        let fields = stat[stat.rfind(')') + 2 .. ^1].splitWhitespace
        if fields[1] == self and fields[0] == "Z": inc result
      except CatchableError: discard

proc spawnShell(r: Reaper; script: string; callback: ChildCallback = nil): SpawnedProcess =
  result = spawn(ProcessSpec(executable: "/bin/sh", arguments: @["-c", script],
    workingDirectory: "/", environment: buildSystemEnvironment()), r,
    owner = "test", callback = callback)
  closeFd(result.stdoutFd); closeFd(result.stderrFd)

suite "central reaper":
  test "owned exits go to their callback only; polling owners use takeCompleted":
    let r = newReaper()
    defer: r.close()
    var seen: seq[ChildStatus]
    let a = spawnShell(r, "exit 3", proc(s: ChildStatus) = seen.add s)
    let b = spawnShell(r, "exit 4")
    check r.owner(a.pid) == "test"
    var status: ChildStatus
    check r.waitFor(proc(): bool = seen.len == 1 and r.takeCompleted(b.pid, status))
    check seen[0].kind == cekExited and seen[0].code == 3
    check status.code == 4
    var again: ChildStatus
    check not r.takeCompleted(a.pid, again)   # never duplicated into the table
    check r.registeredCount == 0

  test "signals reach only registered, unreaped children (PID reuse guard)":
    let r = newReaper()
    defer: r.close()
    var exited = false
    let child = spawnShell(r, "sleep 30", proc(s: ChildStatus) = exited = true)
    check r.signalChild(child.pid, SIGTERM)
    check r.waitFor(proc(): bool = exited)
    # Once reaped the PID may be reused by the kernel; the reaper refuses.
    check not r.signalChild(child.pid, SIGTERM)
    check not r.signalChild(Pid(1), SIGTERM)

  test "SIGCHLD wakes the poll descriptor and drainWakeup reaps everything":
    let r = newReaper()
    defer: r.close()
    installSigChldHandler(r)
    var count = 0
    for i in 0 ..< 5:
      discard spawnShell(r, "exit 0", proc(s: ChildStatus) = inc count)
    var pfd = TPollfd(fd: r.wakeupFd, events: POLLIN)
    var woke = false
    for _ in 0 .. 200:
      if poll(addr pfd, 1, 10) > 0: woke = true
      if woke: break
    check woke
    check r.waitFor(proc(): bool = count == 5)
    check zombieChildren() == 0

  when defined(linux):
    test "installReaper makes a non-PID-1 daemon a subreaper; orphans are reaped silently":
      let r = newReaper()
      defer: r.close()
      var unowned: seq[ChildStatus]
      r.onUnowned = proc(s: ChildStatus) = unowned.add s
      installReaper(r, isPid1 = false)
      proc prctl(option: cint; arg2: ptr cint): cint {.importc, header: "<sys/prctl.h>", varargs.}
      var flag: cint = 0
      check prctl(37, addr flag) == 0  # PR_GET_CHILD_SUBREAPER
      check flag == 1
      var parentDone = false
      # The parent exits at once; its three background children are orphans
      # that now reparent to us, not to init.
      discard spawnShell(r, "sleep 0.2 & sleep 0.2 & sleep 0.2 & exit 0",
                         proc(s: ChildStatus) = parentDone = true)
      check r.waitFor(proc(): bool = parentDone and r.unownedReaped >= 3)
      check unowned.len >= 3
      check zombieChildren() == 0
  else:
    test "subreapers are Linux-only":
      expect OSError: installReaper(newReaper(), isPid1 = false)
