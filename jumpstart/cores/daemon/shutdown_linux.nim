## Linux effects and trigger bridge for the pure shutdown planner (§20.8,
## §20.9).
##
## All destructive operations sit behind `LinuxShutdownSystem`. Production
## uses `defaultLinuxShutdownSystem`; tests use recording fakes.
##
## Triggers: signal handlers (SIGTERM, and on PID 1 SIGINT/SIGPWR) and jumpctl
## power commands (`requestShutdownTrigger`) only record the trigger and write
## one byte to a non-blocking self-pipe. The event loop polls
## `shutdownTriggerFd()` (so a blocking accept restarted by SA_RESTART cannot
## hide a trigger) and calls `takeShutdownTrigger`.
import std/[os, strutils]
when defined(linux):
  import std/[monotimes, times]
import posix
import ./shutdown
import jumpstartcore/[cgroups, peercred]

type
  LinuxShutdownError* = object of CatchableError

  LinuxShutdownSystem* = object
    now*: proc(): float {.closure.}
    pause*: proc(milliseconds: int) {.closure.}
    reap*: proc() {.closure.}
      ## Drain the central reaper; called while waiting so killed children of
      ## PID 1 do not linger as zombies.
    signalPid*: proc(pid, signal: int) {.closure.}
    processAlive*: proc(pid: int): bool {.closure.}
    signalAllExceptSelf*: proc(signal: int) {.closure.}
    remainingProcesses*: proc(): bool {.closure.}
    readText*: proc(path: string): string {.closure.}
    writeText*: proc(path, value: string) {.closure.}
    swapOff*: proc(path: string) {.closure.}
    unmount*: proc(path: string; detach: bool) {.closure.}
    remountRootReadOnly*: proc() {.closure.}
    syncFilesystems*: proc() {.closure.}
    reboot*: proc(action: FinalAction) {.closure.}

  LinuxShutdownConfig* = object
    swapsPath*: string
    mountInfoPath*: string
    userPid*: proc(uid: int): int {.closure.}
      ## PID of the user's daemon, or <= 1 when none is running.
    userCgroup*: proc(uid: int): string {.closure.}
      ## users/UID/ directory, or "" without cgroups.
    coreCgroup*: proc(name: string): string {.closure.}
      ## cores/CORE/ directory, or "" without cgroups.
    cgroupSystem*: CgroupSystem
      ## Used to kill (cgroup.kill, wait populated 0) and remove subtrees.
    markCoreUnloaded*: proc(name: string) {.closure.}
      ## §20.8 step 3: after a forced cgroup kill the core is `unloaded`.

const
  DefaultSwapsPath* = "/proc/swaps"
  DefaultMountInfoPath* = "/proc/self/mountinfo"
  ShutdownPollMilliseconds* = 10
  PfKthread* = 0x00200000'u64

proc defaultLinuxShutdownConfig*(): LinuxShutdownConfig =
  LinuxShutdownConfig(swapsPath: DefaultSwapsPath,
                      mountInfoPath: DefaultMountInfoPath,
                      cgroupSystem: defaultCgroupSystem())

proc require(callbackPresent: bool; name: string) =
  if not callbackPresent:
    raise newException(LinuxShutdownError, "missing Linux shutdown operation: " & name)

proc decodeProcPath*(encoded: string): string =
  ## Decode the octal escapes used by procfs mount and swap tables.
  var i = 0
  while i < encoded.len:
    if encoded[i] == '\\' and i + 3 < encoded.len and
        encoded[i + 1] in {'0'..'7'} and encoded[i + 2] in {'0'..'7'} and
        encoded[i + 3] in {'0'..'7'}:
      result.add char((ord(encoded[i + 1]) - ord('0')) * 64 +
                      (ord(encoded[i + 2]) - ord('0')) * 8 +
                       ord(encoded[i + 3]) - ord('0'))
      inc i, 4
    else:
      result.add encoded[i]
      inc i

proc swapPaths*(text: string): seq[string] =
  var first = true
  for line in text.splitLines:
    if first:
      first = false
      if line.startsWith("Filename"): continue
    let fields = line.splitWhitespace
    if fields.len > 0: result.add decodeProcPath(fields[0])

proc mountPaths*(text: string): seq[string] =
  ## mountinfo field 5 is the mount point. Preserve kernel listing order;
  ## callers unmount the returned sequence backwards.
  for line in text.splitLines:
    let fields = line.splitWhitespace
    if fields.len >= 6 and "-" in fields:
      result.add decodeProcPath(fields[4])

proc protectedMount*(path: string): bool =
  path in ["/", "/proc", "/sys", "/dev", "/run"]

proc remainingProcessesIn*(procRoot: string; selfPid: int): bool =
  ## True while a process other than PID 1 and the caller exists. Kernel
  ## threads (PF_KTHREAD, kthreadd and its children) are not processes that
  ## can be signalled away and are ignored, as are zombies that the reaper
  ## has not collected yet and entries that vanish while scanning.
  for kind, path in walkDir(procRoot):
    if kind != pcDir: continue
    let name = lastPathPart(path)
    if name.len == 0 or not name.allCharsInSet({'0'..'9'}): continue
    let pid = try: parseInt(name) except ValueError: continue
    if pid <= 1 or pid == selfPid: continue
    var stat: string
    try: stat = readFile(path / "stat")
    except CatchableError: continue
    try:
      if (parseStatFlags(stat) and PfKthread) != 0: continue
      if parseStatState(stat) in {'Z', 'X', 'x'}: continue
    except ValueError: continue
    return true

proc waitUntil(deadline: float; done: proc(): bool {.closure.};
               sys: LinuxShutdownSystem): bool =
  require(not sys.now.isNil, "clock")
  require(not sys.pause.isNil, "pause")
  while true:
    if not sys.reap.isNil:
      try: sys.reap()
      except CatchableError: discard
    if done(): return true
    if sys.now() >= deadline: return false
    sys.pause(ShutdownPollMilliseconds)

proc killAndRemove(path: string; config: LinuxShutdownConfig;
                   sys: LinuxShutdownSystem) =
  if path.len == 0: return
  var cg = config.cgroupSystem
  if cg.exists.isNil:
    # Without a cgroup abstraction, fall back to the plain kill file.
    require(not sys.writeText.isNil, "cgroup kill")
    sys.writeText(path / "cgroup.kill", "1")
    return
  # Waiting for the kill also needs the reaper to collect PID 1's children.
  if not sys.reap.isNil and not cg.pause.isNil:
    let basePause = cg.pause
    let reap = sys.reap
    cg.pause = proc(milliseconds: int) =
      try: reap()
      except CatchableError: discard
      basePause(milliseconds)
  killCgroup(path, cg)
  removeCgroupTree(path, cg)

proc linuxShutdownOps*(config: LinuxShutdownConfig;
                       sys: LinuxShutdownSystem;
                       enterShutdown: proc() {.closure.};
                       closeSocket: proc() {.closure.};
                       unloadCore: proc(name: string;
                         deadline: float): bool {.closure.};
                       logFailure: proc(step, message: string) {.closure.}
                      ): ShutdownOps =
  ## Adapt Linux primitives to every step of the planner. No callback is
  ## invoked while constructing this value. `sys.now` must be a real
  ## monotonic clock (defaultLinuxShutdownSystem provides one), so the 30 s,
  ## 90 s, 5 s, 20 s and 25 s limits fire.
  require(not sys.now.isNil, "clock")
  result.now = sys.now
  result.enterShutdown = enterShutdown
  result.closeSocket = closeSocket
  result.unloadCore = unloadCore
  result.logFailure = logFailure

  result.signalUser = proc(uid: int; signal: ShutdownSignal) =
    require(not config.userPid.isNil, "user PID lookup")
    require(not sys.signalPid.isNil, "signal process")
    let pid = config.userPid(uid)
    if pid > 1: sys.signalPid(pid, if signal == ssTerm: int(SIGTERM) else: int(SIGKILL))

  result.waitUser = proc(uid: int; deadline: float): bool =
    require(not config.userPid.isNil, "user PID lookup")
    require(not sys.processAlive.isNil, "process liveness")
    waitUntil(deadline, proc(): bool =
      let pid = config.userPid(uid)
      pid <= 1 or not sys.processAlive(pid), sys)

  result.killUserCgroup = proc(uid: int) =
    require(not config.userCgroup.isNil, "user cgroup lookup")
    killAndRemove(config.userCgroup(uid), config, sys)

  result.killCoreCgroup = proc(name: string) =
    require(not config.coreCgroup.isNil, "core cgroup lookup")
    try: killAndRemove(config.coreCgroup(name), config, sys)
    finally:
      if not config.markCoreUnloaded.isNil: config.markCoreUnloaded(name)

  result.signalRemaining = proc(signal: ShutdownSignal) =
    require(not sys.signalAllExceptSelf.isNil, "signal remaining processes")
    sys.signalAllExceptSelf(if signal == ssTerm: int(SIGTERM) else: int(SIGKILL))

  result.waitRemaining = proc(deadline: float): bool =
    require(not sys.remainingProcesses.isNil, "remaining process scan")
    waitUntil(deadline, proc(): bool = not sys.remainingProcesses(), sys)

  result.deactivateSwap = proc() =
    require(not sys.readText.isNil, "read swaps")
    require(not sys.swapOff.isNil, "swapoff")
    let path = if config.swapsPath.len == 0: DefaultSwapsPath else: config.swapsPath
    var failures: seq[string]
    for swap in swapPaths(sys.readText(path)):
      try: sys.swapOff(swap)
      except CatchableError as error: failures.add(swap & ": " & error.msg)
    if failures.len > 0:
      raise newException(LinuxShutdownError, "swapoff failed: " & failures.join("; "))

  result.unmountFilesystems = proc() =
    ## Reverse mountinfo order. A mount that cannot be unmounted is detached
    ## lazily and logged; a failed detach is logged and the remaining mounts
    ## are still processed.
    require(not sys.readText.isNil, "read mountinfo")
    require(not sys.unmount.isNil, "unmount")
    let path = if config.mountInfoPath.len == 0: DefaultMountInfoPath else: config.mountInfoPath
    let mounts = mountPaths(sys.readText(path))
    for i in countdown(mounts.high, 0):
      let mount = mounts[i]
      if protectedMount(mount): continue
      try:
        sys.unmount(mount, false)
      except CatchableError as error:
        if not logFailure.isNil:
          try: logFailure("unmount " & mount, error.msg & "; detaching lazily")
          except CatchableError: discard
        try:
          sys.unmount(mount, true)
        except CatchableError as detachError:
          if not logFailure.isNil:
            try: logFailure("detach " & mount, detachError.msg)
            except CatchableError: discard

  result.remountRootReadOnly = proc() =
    require(not sys.remountRootReadOnly.isNil, "remount root")
    sys.remountRootReadOnly()
  result.syncFilesystems = proc() =
    require(not sys.syncFilesystems.isNil, "sync")
    sys.syncFilesystems()
  result.finalAction = proc(action: FinalAction) =
    if action == faExit: return
    require(not sys.reboot.isNil, "reboot")
    sys.reboot(action)

# Triggers -------------------------------------------------------------------

var pendingPower {.volatile.}: cint
var pendingTerm {.volatile.}: cint
var pendingInterrupt {.volatile.}: cint
var pendingCommand {.volatile.}: cint  # 0 none, else ord(trigger) + 1
var triggerPipe: array[2, cint] = [-1.cint, -1.cint]

proc wakeTriggerPipe() =
  if triggerPipe[1] >= 0:
    var token = 's'
    discard posix.write(triggerPipe[1], addr token, 1) # EAGAIN: wake pending

proc shutdownSignalHandler(signalNumber: cint) {.noconv.} =
  let saved = errno
  if signalNumber == SIGTERM: pendingTerm = 1
  elif signalNumber == SIGINT: pendingInterrupt = 1
  when declared(SIGPWR):
    if signalNumber == SIGPWR: pendingPower = 1
  wakeTriggerPipe()
  errno = saved

proc ensureTriggerPipe() =
  if triggerPipe[0] >= 0: return
  var fds: array[2, cint]
  if posix.pipe(fds) != 0: raiseOSError(osLastError())
  for fd in fds:
    if fcntl(fd, F_SETFD, FD_CLOEXEC) < 0 or
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) or O_NONBLOCK) < 0:
      let err = osLastError()
      discard posix.close(fds[0]); discard posix.close(fds[1])
      raiseOSError(err)
  triggerPipe = fds

proc installHandler(signalNumber: cint) =
  var action: Sigaction
  action.sa_handler = shutdownSignalHandler
  discard sigemptyset(action.sa_mask)
  action.sa_flags = SA_RESTART
  if sigaction(signalNumber, action, nil) != 0: raiseOSError(osLastError())

proc installShutdownTriggers*(mode: ShutdownMode): cint =
  ## Install exactly the specified signal triggers and return the descriptor
  ## the event loop must poll for readability. System mode: SIGTERM, SIGINT
  ## (Ctrl-Alt-Del once `disableCtrlAltDel` ran) and SIGPWR. User mode:
  ## SIGTERM only (§20.9).
  ensureTriggerPipe()
  installHandler(SIGTERM)
  if mode == smSystem:
    installHandler(SIGINT)
    when declared(SIGPWR):
      installHandler(SIGPWR)
  triggerPipe[0]

proc installShutdownSignalHandlers*(mode: ShutdownMode) =
  ## Compatibility wrapper; prefer installShutdownTriggers and poll its fd.
  discard installShutdownTriggers(mode)

proc shutdownTriggerFd*(): cint = triggerPipe[0]

proc requestShutdownTrigger*(trigger: ShutdownTrigger) =
  ## jumpctl poweroff/reboot/halt: queue the command trigger for the event
  ## loop. The first trigger still wins inside `shutdown.trigger`.
  if pendingCommand == 0: pendingCommand = cint(ord(trigger) + 1)
  wakeTriggerPipe()

proc powerTrigger*(action: string): ShutdownTrigger =
  ## Map a `power` request action (§14.5, §21.6) to its trigger.
  case action
  of "poweroff": stPoweroffCommand
  of "reboot": stRebootCommand
  of "halt": stHaltCommand
  else: raise newException(ValueError, "unknown power action: " & action)

proc drainTriggerPipe() =
  if triggerPipe[0] < 0: return
  var buffer: array[64, char]
  while true:
    let n = posix.read(triggerPipe[0], addr buffer[0], buffer.len)
    if n > 0: continue
    if n < 0 and osLastError() == OSErrorCode(EINTR): continue
    break

proc takeShutdownTrigger*(mode: ShutdownMode; trigger: var ShutdownTrigger): bool =
  ## Returns one pending trigger, in arrival-independent priority order (only
  ## relevant when several arrive within one event-loop turn). Pass it to
  ## `shutdown.trigger`, whose first-trigger rule is final; call again until
  ## it returns false to log later triggers as ignored.
  drainTriggerPipe()
  if pendingCommand != 0:
    trigger = ShutdownTrigger(pendingCommand - 1)
    pendingCommand = 0
    return true
  if pendingTerm != 0:
    pendingTerm = 0
    trigger = stSigTerm
    return true
  if mode == smSystem:
    if pendingInterrupt != 0:
      pendingInterrupt = 0
      trigger = stSigInt
      return true
    if pendingPower != 0:
      pendingPower = 0
      trigger = stSigPower
      return true

proc takeShutdownSignal*(mode: ShutdownMode; trigger: var ShutdownTrigger): bool =
  ## Compatibility name for takeShutdownTrigger.
  takeShutdownTrigger(mode, trigger)

when defined(linux):
  proc cSwapoff(path: cstring): cint {.importc: "swapoff", header: "<sys/swap.h>".}
  proc cUmount2(path: cstring; flags: cint): cint {.importc: "umount2", header: "<sys/mount.h>".}
  proc cMount(source, target, fsType: cstring; flags: culong;
              data: pointer): cint {.importc: "mount", header: "<sys/mount.h>".}
  proc cReboot(command: cint): cint {.importc: "reboot", header: "<sys/reboot.h>".}
  proc cSync() {.importc: "sync", header: "<unistd.h>".}

  const
    LinuxMountReadOnly = 1.culong
    LinuxMountRemount = 32.culong
    LinuxMountDetach = 2.cint
    LinuxRebootPowerOff = 0x4321FEDC.cint
    LinuxRebootRestart = 0x01234567.cint
    LinuxRebootHalt = cast[cint](0xCDEF0123'u32)
    LinuxRebootCadOff = 0.cint

proc disableCtrlAltDel*() =
  ## §20.2: reboot(RB_DISABLE_CAD) so Ctrl-Alt-Del arrives as SIGINT.
  when defined(linux):
    if cReboot(LinuxRebootCadOff) != 0: raiseOSError(osLastError(), "RB_DISABLE_CAD")
  else:
    raise newException(LinuxShutdownError, "Ctrl-Alt-Del control requires Linux")

proc defaultLinuxShutdownSystem*(reap: proc() {.closure.} = nil): LinuxShutdownSystem =
  ## `reap` should drain the daemon's central reaper.
  when defined(linux):
    let boot = getMonoTime()
    result.now = proc(): float =
      float((getMonoTime() - boot).inNanoseconds) / 1_000_000_000.0
    result.pause = proc(milliseconds: int) = sleep(milliseconds)
    result.reap = reap
    result.signalPid = proc(pid, signalNumber: int) =
      if kill(Pid(pid), cint(signalNumber)) != 0 and osLastError() != OSErrorCode(ESRCH):
        raiseOSError(osLastError())
    result.processAlive = proc(pid: int): bool =
      if kill(Pid(pid), 0) == 0:
        # A zombie still answers kill(0); treat it as exited.
        try: return parseStatState(readFile("/proc/" & $pid & "/stat")) notin {'Z', 'X'}
        except CatchableError: return false
      let error = osLastError()
      if error == OSErrorCode(ESRCH): return false
      if error == OSErrorCode(EPERM): return true
      raiseOSError(error)
    result.signalAllExceptSelf = proc(signalNumber: int) =
      if kill(Pid(-1), cint(signalNumber)) != 0 and osLastError() != OSErrorCode(ESRCH):
        raiseOSError(osLastError())
    result.remainingProcesses = proc(): bool =
      remainingProcessesIn("/proc", int(getpid()))
    result.readText = proc(path: string): string = readFile(path)
    result.writeText = proc(path, value: string) = writeFile(path, value)
    result.swapOff = proc(path: string) =
      if cSwapoff(path.cstring) != 0: raiseOSError(osLastError(), path)
    result.unmount = proc(path: string; detach: bool) =
      if cUmount2(path.cstring, if detach: LinuxMountDetach else: 0) != 0:
        raiseOSError(osLastError(), path)
    result.remountRootReadOnly = proc() =
      if cMount(nil, "/", nil, LinuxMountRemount or LinuxMountReadOnly, nil) != 0:
        raiseOSError(osLastError(), "/")
    result.syncFilesystems = proc() = cSync()
    result.reboot = proc(action: FinalAction) =
      let command = case action
        of faPowerOff: LinuxRebootPowerOff
        of faReboot: LinuxRebootRestart
        of faHalt: LinuxRebootHalt
        else: raise newException(ValueError, "invalid Linux reboot action")
      if cReboot(command) != 0: raiseOSError(osLastError())
  else:
    if reap.isNil: discard
    raise newException(LinuxShutdownError,
      "the operational shutdown backend is available only on Linux")
