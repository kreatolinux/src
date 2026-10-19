## Ordered, effect-injected shutdown policy (§20.8 and §20.9).
##
## This module deliberately contains no signal installation, socket, process,
## mount, or reboot code. The daemon supplies those effects through
## `ShutdownOps` (production: `shutdown_linux.linuxShutdownOps`); tests supply
## a clock and recording callbacks. A missing effect is logged as a failed
## step, never silently skipped, and the sequence still reaches its final
## action.

type
  ShutdownMode* = enum
    smSystem, smUser

  ShutdownTrigger* = enum
    stPoweroffCommand, stRebootCommand, stHaltCommand,
    stSigPower, stSigTerm, stSigInt

  FinalAction* = enum
    faNone, faPowerOff, faReboot, faHalt, faExit

  ShutdownPhase* = enum
    spIdle, spClosingSocket, spStoppingUsers, spUnloadingCores,
    spStoppingProcesses, spStorage, spFinalAction, spFinished
    ## spClosingSocket is step 1, "enter shutdown": the socket stays open for
    ## status requests; it is closed just before the final action.

  TriggerResult* = enum
    trStarted, trIgnored, trUnsupported

  ShutdownSignal* = enum
    ssTerm, ssKill

  TriggerLogProc* = proc(message: string) {.closure.}

  ShutdownState* = object
    mode*: ShutdownMode
    phase*: ShutdownPhase
    action*: FinalAction
    trigger*: ShutdownTrigger
    ignoredTriggers*: int

  ShutdownPlan* = object
    ## Inputs are in their normal/load order. Execution reverses both lists.
    mode*: ShutdownMode
    users*: seq[int]
    cores*: seq[string]

  ShutdownOps* = object
    now*: proc(): float {.closure.}
      ## Monotonic seconds. Required: every limit is measured with it.
    enterShutdown*: proc() {.closure.}
      ## Step 1: from now on only status (and, in system mode, cores status)
      ## requests are served; others get E_SHUTDOWN.
    signalUser*: proc(uid: int; signal: ShutdownSignal) {.closure.}
    waitUser*: proc(uid: int; deadline: float): bool {.closure.}
      ## True once the user daemon exited; must return by `deadline`.
    killUserCgroup*: proc(uid: int) {.closure.}
    unloadCore*: proc(name: string; deadline: float): bool {.closure.}
      ## The §20.4 procedure with units stopped and daemonShutdown set.
    killCoreCgroup*: proc(name: string) {.closure.}
      ## Kill and remove the core's cgroup and mark the core `unloaded`.
    signalRemaining*: proc(signal: ShutdownSignal) {.closure.}
    waitRemaining*: proc(deadline: float): bool {.closure.}
    deactivateSwap*: proc() {.closure.}
    unmountFilesystems*: proc() {.closure.}
    remountRootReadOnly*: proc() {.closure.}
    syncFilesystems*: proc() {.closure.}
    closeSocket*: proc() {.closure.}
      ## Close and unlink the control socket, right before the final action.
    finalAction*: proc(action: FinalAction) {.closure.}
    logFailure*: proc(step, message: string) {.closure.}

const
  SystemUserDeadlineSeconds* = 30.0
  SystemCoreDeadlineSeconds* = 90.0
  RemainingProcessDeadlineSeconds* = 5.0
  UserCoreDeadlineSeconds* = 20.0
  UserTotalDeadlineSeconds* = 25.0

proc initShutdownState*(mode: ShutdownMode): ShutdownState =
  ShutdownState(mode: mode, phase: spIdle, action: faNone)

proc actionForTrigger*(mode: ShutdownMode; trigger: ShutdownTrigger): FinalAction =
  case mode
  of smUser:
    if trigger == stSigTerm: faExit else: faNone
  of smSystem:
    case trigger
    of stPoweroffCommand, stSigPower, stSigTerm: faPowerOff
    of stRebootCommand, stSigInt: faReboot
    of stHaltCommand: faHalt

proc trigger*(state: var ShutdownState; cause: ShutdownTrigger;
              logIgnored: TriggerLogProc = nil): TriggerResult =
  ## Atomically applies the "first trigger wins" policy. Unsupported events
  ## are not shutdown triggers and consequently do not consume the first one.
  let action = actionForTrigger(state.mode, cause)
  if action == faNone: return trUnsupported
  if state.phase != spIdle:
    inc state.ignoredTriggers
    if not logIgnored.isNil:
      try: logIgnored("shutdown trigger ignored: " & $cause)
      except CatchableError: discard
    return trIgnored
  state.trigger = cause
  state.action = action
  state.phase = spClosingSocket
  trStarted

proc shuttingDown*(state: ShutdownState): bool = state.phase != spIdle

proc requestAllowed*(state: ShutdownState; request: string): bool =
  ## §20.8 step 1: the system daemon still serves `status` and
  ## `cores status`; §20.9: a user daemon serves only `status`.
  if state.phase == spIdle: return true
  case state.mode
  of smSystem: request == "status" or request == "cores status"
  of smUser: request == "status"

proc reverseOrder*[T](items: openArray[T]): seq[T] =
  for i in countdown(items.high, 0): result.add(items[i])

proc safeLog(ops: ShutdownOps; step, message: string) =
  if not ops.logFailure.isNil:
    try: ops.logFailure(step, message)
    except CatchableError: discard

proc failed(ops: ShutdownOps; step: string; error: ref Exception) =
  ops.safeLog(step, error.msg)

proc unavailable(ops: ShutdownOps; step: string) =
  ops.safeLog(step, "operation unavailable")

proc clock(ops: ShutdownOps): float =
  if ops.now.isNil: 0.0 else: ops.now()

template effect(ops: ShutdownOps; field: untyped; step: string; body: untyped) =
  if ops.field.isNil: ops.unavailable(step)
  else:
    # A Defect in one step must not stop the sequence: step 7 always runs (§20.8).
    try: body
    except Exception as error: ops.failed(step, error)

proc stopUsers(ops: ShutdownOps; users: seq[int]) =
  ## §20.8 step 2, in parallel: every user daemon gets SIGTERM first, then all
  ## of them share one 30-second deadline, then the survivors get SIGKILL and
  ## every user cgroup is killed. The whole step is bounded by 30 s (plus the
  ## kills), however many users there are.
  let ordered = reverseOrder(users)
  for uid in ordered:
    ops.effect(signalUser, "terminate user " & $uid):
      ops.signalUser(uid, ssTerm)
  let deadline = ops.clock + SystemUserDeadlineSeconds
  var survivors: seq[int]
  for uid in ordered:
    var stopped = false
    ops.effect(waitUser, "wait for user " & $uid):
      stopped = ops.waitUser(uid, deadline)
    if not stopped: survivors.add uid
  for uid in survivors:
    ops.effect(signalUser, "kill user " & $uid):
      ops.signalUser(uid, ssKill)
  # The cgroup is killed even after a clean exit, as required by the system
  # sequence; this also catches descendants that escaped waiting.
  for uid in ordered:
    ops.effect(killUserCgroup, "kill user cgroup " & $uid):
      ops.killUserCgroup(uid)

proc runShutdown*(state: var ShutdownState; plan: ShutdownPlan;
                  ops: ShutdownOps) =
  ## Runs a previously accepted shutdown. Every failing effect is isolated so
  ## system shutdown always reaches the reboot operation. A callback returning
  ## false means its wait/unload did not complete before the supplied deadline.
  if state.phase == spIdle:
    raise newException(ValueError, "shutdown has not been triggered")
  if state.phase == spFinished: return
  if state.mode != plan.mode:
    raise newException(ValueError, "shutdown plan mode does not match state")
  if ops.now.isNil: ops.unavailable("clock")

  let shutdownStarted = ops.clock
  state.phase = spClosingSocket
  ops.effect(enterShutdown, "enter shutdown"):
    ops.enterShutdown()

  if plan.mode == smSystem:
    state.phase = spStoppingUsers
    ops.stopUsers(plan.users)

  state.phase = spUnloadingCores
  let totalDeadline = shutdownStarted + UserTotalDeadlineSeconds
  var forceRemaining = false
  for name in reverseOrder(plan.cores):
    if plan.mode == smUser and (forceRemaining or ops.clock >= totalDeadline):
      forceRemaining = true
    var unloaded = false
    if not forceRemaining:
      let perCore = ops.clock +
        (if plan.mode == smUser: UserCoreDeadlineSeconds
         else: SystemCoreDeadlineSeconds)
      let deadline =
        if plan.mode == smUser and totalDeadline < perCore: totalDeadline
        else: perCore
      ops.effect(unloadCore, "unload core " & name):
        unloaded = ops.unloadCore(name, deadline)
      if ops.clock >= deadline:
        # Completion reported at/after expiry loses to the deadline.
        unloaded = false
        # §20.9: when either user limit expires, skip to the cgroup kill of
        # every remaining core.
        if plan.mode == smUser: forceRemaining = true
    if not unloaded:
      ops.effect(killCoreCgroup, "kill core cgroup " & name):
        ops.killCoreCgroup(name)

  if plan.mode == smSystem:
    state.phase = spStoppingProcesses
    ops.effect(signalRemaining, "terminate remaining processes"):
      ops.signalRemaining(ssTerm)
    var stopped = false
    let deadline = ops.clock + RemainingProcessDeadlineSeconds
    ops.effect(waitRemaining, "wait for remaining processes"):
      stopped = ops.waitRemaining(deadline)
    if not stopped:
      ops.effect(signalRemaining, "kill remaining processes"):
        ops.signalRemaining(ssKill)

    state.phase = spStorage
    ops.effect(deactivateSwap, "deactivate swap"): ops.deactivateSwap()
    ops.effect(unmountFilesystems, "unmount filesystems"): ops.unmountFilesystems()
    ops.effect(remountRootReadOnly, "remount root read-only"): ops.remountRootReadOnly()
    ops.effect(syncFilesystems, "sync"): ops.syncFilesystems()

  state.phase = spFinalAction
  ops.effect(closeSocket, "close socket"): ops.closeSocket()
  ops.effect(finalAction, "final action"): ops.finalAction(state.action)
  state.phase = spFinished
