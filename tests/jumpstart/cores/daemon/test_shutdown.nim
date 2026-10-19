import std/[os, sequtils, strutils, unittest]
import posix
import ../../../../jumpstart/cores/daemon/[shutdown, shutdown_linux]

suite "ordered shutdown planner":
  test "trigger mapping is exact and the first trigger wins":
    var systemState = initShutdownState(smSystem)
    check systemState.trigger(stSigInt) == trStarted
    check systemState.action == faReboot
    var ignored = ""
    check systemState.trigger(stPoweroffCommand,
      proc(message: string) = ignored = message) == trIgnored
    check ignored.contains("stPoweroffCommand")
    check systemState.action == faReboot
    check systemState.ignoredTriggers == 1
    check not systemState.requestAllowed("service start")
    check systemState.requestAllowed("status")
    check systemState.requestAllowed("cores status")
    for (trigger, action) in [(stPoweroffCommand, faPowerOff), (stSigPower, faPowerOff),
                              (stSigTerm, faPowerOff), (stRebootCommand, faReboot),
                              (stHaltCommand, faHalt)]:
      check actionForTrigger(smSystem, trigger) == action

    var userState = initShutdownState(smUser)
    check userState.trigger(stSigInt) == trUnsupported
    check userState.phase == spIdle
    check userState.trigger(stSigTerm) == trStarted
    check userState.action == faExit
    check userState.requestAllowed("status")
    check not userState.requestAllowed("cores status")   # §20.9: only status

  test "system shutdown is ordered, reversed, parallel for users, with fixed deadlines":
    var now = 100.0
    var calls: seq[string]
    var userDeadlines: seq[float]
    var coreDeadlines: seq[float]
    var remainingDeadline = 0.0
    var ops: ShutdownOps
    ops.now = proc(): float = now
    ops.enterShutdown = proc() = calls.add("enter")
    ops.closeSocket = proc() = calls.add("close")
    ops.signalUser = proc(uid: int; signal: ShutdownSignal) =
      calls.add("user:" & $uid & ":" & $signal)
    ops.waitUser = proc(uid: int; deadline: float): bool =
      userDeadlines.add(deadline)
      uid == 20
    ops.killUserCgroup = proc(uid: int) = calls.add("user-cgroup:" & $uid)
    ops.unloadCore = proc(name: string; deadline: float): bool =
      calls.add("unload:" & name)
      coreDeadlines.add(deadline)
      name != "client"
    ops.killCoreCgroup = proc(name: string) = calls.add("core-cgroup:" & name)
    ops.signalRemaining = proc(signal: ShutdownSignal) = calls.add("all:" & $signal)
    ops.waitRemaining = proc(deadline: float): bool =
      remainingDeadline = deadline
      false
    ops.deactivateSwap = proc() = calls.add("swap")
    ops.unmountFilesystems = proc() = calls.add("unmount")
    ops.remountRootReadOnly = proc() = calls.add("root-ro")
    ops.syncFilesystems = proc() = calls.add("sync")
    ops.finalAction = proc(action: FinalAction) = calls.add("final:" & $action)

    var state = initShutdownState(smSystem)
    check state.trigger(stPoweroffCommand) == trStarted
    state.runShutdown(ShutdownPlan(mode: smSystem, users: @[10, 20],
      cores: @["target", "client"]), ops)

    check calls == @["enter", "user:20:ssTerm", "user:10:ssTerm", "user:10:ssKill",
      "user-cgroup:20", "user-cgroup:10",
      "unload:client", "core-cgroup:client", "unload:target",
      "all:ssTerm", "all:ssKill", "swap", "unmount", "root-ro",
      "sync", "close", "final:faPowerOff"]
    check userDeadlines == @[130.0, 130.0]   # one shared 30 s deadline
    check coreDeadlines == @[190.0, 190.0]
    check remainingDeadline == 105.0
    check state.phase == spFinished

  test "failures and missing effects are logged and never prevent the final action":
    var calls: seq[string]
    var logs: seq[string]
    var ops: ShutdownOps
    ops.now = proc(): float = 0
    ops.enterShutdown = proc() = raise newException(IOError, "enter failed")
    ops.unloadCore = proc(name: string; deadline: float): bool =
      raise newException(IOError, "unload failed")
    ops.killCoreCgroup = proc(name: string) = calls.add("kill:" & name)
    ops.deactivateSwap = proc() = raise newException(IOError, "swap failed")
    ops.finalAction = proc(action: FinalAction) = calls.add("final:" & $action)
    ops.logFailure = proc(step, message: string) = logs.add(step & ":" & message)
    var state = initShutdownState(smSystem)
    discard state.trigger(stRebootCommand)
    state.runShutdown(ShutdownPlan(mode: smSystem, cores: @["a"]), ops)
    check calls == @["kill:a", "final:faReboot"]
    let text = logs.join("\n")
    check "enter failed" in text
    check "unload failed" in text
    check "swap failed" in text
    check "sync:operation unavailable" in text
    check "remount root read-only:operation unavailable" in text

  test "user shutdown enforces per-core and total deadlines":
    var now = 0.0
    var calls: seq[string]
    var deadlines: seq[float]
    var ops: ShutdownOps
    ops.now = proc(): float = now
    ops.enterShutdown = proc() = calls.add("enter")
    ops.closeSocket = proc() = calls.add("close")
    ops.unloadCore = proc(name: string; deadline: float): bool =
      calls.add("unload:" & name)
      deadlines.add(deadline)
      if name == "c":
        now = 19.0                 # failed before its per-core deadline
        return false
      now = 26.0                 # b crosses the 25-second whole deadline
      true
    ops.killCoreCgroup = proc(name: string) = calls.add("kill:" & name)
    ops.finalAction = proc(action: FinalAction) = calls.add("final:" & $action)
    var state = initShutdownState(smUser)
    check state.trigger(stSigTerm) == trStarted
    state.runShutdown(ShutdownPlan(mode: smUser, cores: @["a", "b", "c"]), ops)
    check deadlines == @[20.0, 25.0]
    check calls == @["enter", "unload:c", "kill:c", "unload:b", "kill:b",
      "kill:a", "close", "final:faExit"]
    check state.phase == spFinished

  test "the 25 second total includes entering shutdown":
    var now = 0.0
    var calls: seq[string]
    var ops: ShutdownOps
    ops.now = proc(): float = now
    ops.enterShutdown = proc() =
      calls.add("enter")
      now = 25.0
    ops.unloadCore = proc(name: string; deadline: float): bool =
      calls.add("unexpected unload")
      true
    ops.killCoreCgroup = proc(name: string) = calls.add("kill:" & name)
    ops.closeSocket = proc() = calls.add("close")
    ops.finalAction = proc(action: FinalAction) = calls.add("final")
    var state = initShutdownState(smUser)
    discard state.trigger(stSigTerm)
    state.runShutdown(ShutdownPlan(mode: smUser, cores: @["a", "b"]), ops)
    check calls == @["enter", "kill:b", "kill:a", "close", "final"]

suite "Linux shutdown effects":
  proc fakeSystem(clock: ref float; calls: ref seq[string]): LinuxShutdownSystem =
    ## Time advances only while waiting (pause), like a real clock would.
    result.now = proc(): float = clock[]
    result.pause = proc(milliseconds: int) = clock[] += float(milliseconds) / 1000.0
    result.reap = proc() = discard
    result.signalPid = proc(pid, signal: int) = calls[].add("signal " & $pid & " " & $signal)
    result.processAlive = proc(pid: int): bool = true      # nobody exits
    result.signalAllExceptSelf = proc(signal: int) = calls[].add("all " & $signal)
    result.remainingProcesses = proc(): bool = true
    result.readText = proc(path: string): string =
      if path.endsWith("swaps"):
        "Filename Type Size Used Priority\n/dev/sda2 partition 100 0 -2\n"
      else:
        "1 0 8:1 / / rw - ext4 /dev/sda1 rw\n" &
        "2 1 0:5 / /proc rw - proc proc rw\n" &
        "3 1 8:2 / /home rw - ext4 /dev/sda3 rw\n" &
        "4 3 0:40 / /home/stuck rw - fuse fuse rw\n" &
        "5 1 0:41 / /mnt/busy rw - tmpfs tmpfs rw\n"
    result.writeText = proc(path, value: string) = calls[].add("write " & path)
    result.swapOff = proc(path: string) = calls[].add("swapoff " & path)
    result.unmount = proc(path: string; detach: bool) =
      calls[].add((if detach: "detach " else: "umount ") & path)
      if path == "/mnt/busy": raise newException(OSError, "EBUSY")
      if path == "/home/stuck": raise newException(OSError, "EINVAL")
    result.remountRootReadOnly = proc() = calls[].add("remount-ro")
    result.syncFilesystems = proc() = calls[].add("sync")
    result.reboot = proc(action: FinalAction) = calls[].add("reboot " & $action)

  test "users stop in parallel within one 30 s bound; every step reaches reboot":
    var clock: ref float; new(clock); clock[] = 0.0
    var calls: ref seq[string]; new(calls)
    var logs: seq[string]
    var unloaded: seq[string]
    var marked: seq[string]
    var config = defaultLinuxShutdownConfig()
    config.userPid = proc(uid: int): int = uid + 1000
    config.userCgroup = proc(uid: int): string = ""
    config.coreCgroup = proc(name: string): string = ""
    config.markCoreUnloaded = proc(name: string) = marked.add name
    let ops = linuxShutdownOps(config, fakeSystem(clock, calls),
      enterShutdown = proc() = calls[].add("enter"),
      closeSocket = proc() = calls[].add("close"),
      unloadCore = proc(name: string; deadline: float): bool =
        unloaded.add name
        if name == "slow":
          while clock[] < deadline: clock[] += 1.0   # hangs until the limit
          return false
        true,
      logFailure = proc(step, message: string) = logs.add(step & ": " & message))
    var state = initShutdownState(smSystem)
    discard state.trigger(stSigPower)
    var userPhaseEnd = 0.0
    var wrapped = ops
    let baseKillCgroup = ops.killUserCgroup
    wrapped.killUserCgroup = proc(uid: int) =
      userPhaseEnd = clock[]
      baseKillCgroup(uid)
    state.runShutdown(ShutdownPlan(mode: smSystem, users: @[1, 2, 3],
      cores: @["serviceHandler", "slow", "fast"]), wrapped)
    # Three stuck users cost one 30 s wait, not 90 s.
    check userPhaseEnd >= 30.0 and userPhaseEnd < 31.0
    let c = calls[]
    check c[0] == "enter"
    check c[1 .. 3] == @["signal 1003 15", "signal 1002 15", "signal 1001 15"]
    check c[4 .. 6] == @["signal 1003 9", "signal 1002 9", "signal 1001 9"]
    check unloaded == @["fast", "slow", "serviceHandler"]
    check marked == @["slow"]                         # forced kill marks unloaded
    check "all 15" in c and "all 9" in c
    check "swapoff /dev/sda2" in c
    # Reverse mountinfo order, protected mounts skipped; a failed detach is
    # logged and does not stop the remaining unmounts.
    let mounts = c.filterIt(it.startsWith("umount ") or it.startsWith("detach "))
    check mounts == @["umount /mnt/busy", "detach /mnt/busy", "umount /home/stuck",
                      "detach /home/stuck", "umount /home"]
    check c[^4 .. ^1] == @["remount-ro", "sync", "close", "reboot faPowerOff"]
    check logs.join("\n").contains("detach /home/stuck")

  test "the remaining-process scan ignores kernel threads, zombies, PID 1 and itself":
    let root = getTempDir() / ("jumpstart-proc-" & $getCurrentProcessId())
    if dirExists(root): removeDir(root)
    defer: removeDir(root)
    proc entry(pid: int; state: char; flags: uint64) =
      createDir(root / $pid)
      writeFile(root / $pid / "stat", $pid & " (a (b) c) " & $state &
        " 1 1 1 0 -1 " & $flags & " 0 0 0 0 0 0 0 0 20 0 1 0 100 0 0")
    entry(1, 'S', 0)
    entry(2, 'S', 0x00208040'u64)        # kthreadd
    entry(17, 'I', 0x04208060'u64)       # kworker
    entry(40, 'Z', 0)                    # zombie awaiting the reaper
    entry(99, 'S', 0)                    # ourselves
    createDir(root / "self")
    check not remainingProcessesIn(root, 99)
    entry(500, 'S', 0x400100'u64)
    check remainingProcessesIn(root, 99)

  test "triggers arrive through a pollable self-pipe":
    let fd = installShutdownTriggers(smUser)
    check fd >= 0 and fd == shutdownTriggerFd()
    var trigger: ShutdownTrigger
    check not takeShutdownTrigger(smUser, trigger)
    check posix.kill(getpid(), SIGTERM) == 0
    var pfd = TPollfd(fd: fd, events: POLLIN)
    check poll(addr pfd, 1, 2000) == 1
    check takeShutdownTrigger(smUser, trigger)
    check trigger == stSigTerm
    requestShutdownTrigger(powerTrigger("reboot"))
    check poll(addr pfd, 1, 2000) == 1
    check takeShutdownTrigger(smSystem, trigger)
    check trigger == stRebootCommand
    check not takeShutdownTrigger(smSystem, trigger)
    expect ValueError: discard powerTrigger("suspend")

  test "the production clock is monotonic and Ctrl-Alt-Del control is Linux-only":
    when defined(linux):
      let sys = defaultLinuxShutdownSystem()
      let a = sys.now()
      sleep(20)
      check sys.now() - a >= 0.015
    else:
      expect LinuxShutdownError: discard defaultLinuxShutdownSystem()
      expect LinuxShutdownError: disableCtrlAltDel()
