## Pure operation backend resolution, delegation planning, and dispatch locking.
##
## This module deliberately does not spawn or signal processes.  Time is supplied by
## callers as monotonic millisecond values, making timeout and cancellation planning
## deterministic and straightforward to test.
import std/[options, sets, strutils, tables]
import jumpstartcore/errors
import jumpstartcore/registry_types
export registry_types
export errors

const
  MaxDelegationHops* = 4
    ## §13.4: a delegation chain longer than four hops is rejected.
  CancellationGraceMs* = 5_000'i64
    ## §13.7: SIGTERM or `cancel`, wait up to 5 seconds, then SIGKILL.
  MaxTimeoutMs* = 86_400_000'i64
    ## §13.1: the maximum duration is `24h`.

type
  DispatchError* = CoreError

  BackendKind* = enum
    bkCustom, bkExec, bkDelegate, bkUnsupported, bkNative

  ExecMode* = enum
    emOneshot, emPersistent

  OperationInfo* = OperationSpec

  BackendOptions* = object
    timeout*: string
    sandbox*: Option[bool]
    user*: string
    writablePaths*: seq[string]
    network*: bool
    environment*: Table[string, string]
    workingDirectory*: string
    executable*: string
    arguments*: seq[string]
    execMode*: ExecMode
    delegateCore*: string
    delegateOperation*: string
    handler*: string

  BackendSpec* = object
    kind*: BackendKind
    options*: BackendOptions

  ResolvedBackend* = object
    kind*: BackendKind
    timeoutMs*: int64
    sandbox*: Option[bool]
    user*: string
    userIgnored*: bool
    writablePaths*: seq[string]
    network*: bool
    environment*: Table[string, string]
    workingDirectory*: string
    executable*: string
    arguments*: seq[string]
    execMode*: ExecMode
    delegateCore*: string
    delegateOperation*: string
    handler*: string

  PlannedOperation* = object
    core*, operation*: string
    info*: OperationInfo
    backend*: ResolvedBackend

  CoreDispatchPlan* = object
    name*: string
    operations*: Table[string, PlannedOperation]

  DelegationHop* = object
    core*, operation*: string

  DispatchPlan* = object
    requestedCore*, requestedOperation*: string
    target*: PlannedOperation
    chain*: seq[DelegationHop]

  LockKind* = enum
    lkNone, lkUnit, lkCore, lkLog

  LockSelection* = object
    kind*: LockKind
    core*, unit*: string

  RequestState* = enum
    rsWaiting, rsRunning, rsCompleted, rsTimedOut, rsCancelled

  CancellationStep* = enum
    csNone, csTerminateProcessGroup, csCancelPersistentAdapter,
    csKillProcessGroup, csKillPersistentAdapter

  LockTicket* = object
    id*: uint64
    selection*: LockSelection
    deadlineMs*: int64
    state*: RequestState
    cancelStartedMs*: int64
    persistentAdapter*: bool

  LockTransition* = object
    ## A waiting ticket changed state inside the manager: it acquired its
    ## lock (`rsRunning`, start the operation now) or its deadline passed
    ## while waiting (`rsTimedOut`, report `E_TIMEOUT`).
    id*: uint64
    state*: RequestState

  LockManager* = object
    nextId: uint64
    transitions: seq[LockTransition]
    tickets: Table[uint64, LockTicket]
    waiting: seq[uint64]
    coreHolders: Table[string, uint64]
    unitHolders: Table[string, uint64]
    logHolders: Table[string, uint64]

proc fail(code: CoreErrorCode; message: string; core = ""; operation = "") {.noreturn.} =
  let detail = if operation.len == 0: message
               else: message & " (" & operation & ")"
  raise newCoreError(code, detail, core)

proc parseDurationMs*(value: string): int64 =
  if value.len < 2:
    fail(ecManifest, "timeout must be a positive duration")
  var split = 0
  while split < value.len and value[split] in {'0'..'9'}: inc split
  if split == 0:
    fail(ecManifest, "timeout must be a positive duration")
  var number: int64
  try: number = parseBiggestInt(value[0 ..< split])
  except ValueError: fail(ecManifest, "invalid timeout: " & value)
  if number <= 0: fail(ecManifest, "timeout must be positive")
  let multiplier = case value[split .. ^1]
    of "ms": 1'i64
    of "s": 1_000'i64
    of "m": 60_000'i64
    of "h": 3_600_000'i64
    else: fail(ecManifest, "invalid timeout unit: " & value)
  if number > MaxTimeoutMs div multiplier:
    fail(ecManifest, "timeout exceeds 24h")
  number * multiplier

proc operationSubsystem(name: string): string =
  let dot = name.find('.')
  if dot <= 0: "" else: name[0 ..< dot]

proc hasCommonOptions(options: BackendOptions): bool =
  options.timeout.len > 0 or options.sandbox.isSome or options.user.len > 0 or
    options.writablePaths.len > 0 or options.network or options.environment.len > 0 or
    options.workingDirectory.len > 0

proc hasExecOptions(options: BackendOptions): bool =
  options.executable.len > 0 or options.arguments.len > 0 or
    options.execMode == emPersistent

proc resolveBackend*(info: OperationInfo; spec: BackendSpec;
                     manifestAccount = ""; userMode = false;
                     nativeCore = false): ResolvedBackend =
  ## Resolve every documented dispatch default. Static path/account existence
  ## checks remain the manifest/discovery layer's responsibility.
  result.kind = spec.kind
  case spec.kind
  of bkUnsupported:
    if hasCommonOptions(spec.options) or hasExecOptions(spec.options) or
        spec.options.delegateCore.len > 0 or spec.options.delegateOperation.len > 0 or
        spec.options.handler.len > 0:
      fail(ecManifest, "unsupported backend accepts no options or functions")
    return
  of bkNative:
    if not nativeCore: fail(ecManifest, "native backend is reserved for serviceHandler")
    if hasCommonOptions(spec.options) or hasExecOptions(spec.options) or
        spec.options.delegateCore.len > 0 or spec.options.delegateOperation.len > 0 or
        spec.options.handler.len > 0:
      fail(ecManifest, "native backend accepts no options")
    return
  of bkDelegate:
    if hasCommonOptions(spec.options) or hasExecOptions(spec.options) or
        spec.options.handler.len > 0:
      fail(ecManifest, "delegate backend accepts only core and operation")
    if spec.options.delegateCore.len == 0:
      fail(ecManifest, "delegate backend requires core")
    result.delegateCore = spec.options.delegateCore
    result.delegateOperation = spec.options.delegateOperation
    if result.delegateOperation.len == 0: result.delegateOperation = info.name
    if operationSubsystem(result.delegateOperation) != operationSubsystem(info.name):
      fail(ecManifest, "delegation must stay in the same subsystem")
    return
  of bkCustom, bkExec:
    if spec.kind == bkCustom and
        (hasExecOptions(spec.options) or spec.options.delegateCore.len > 0 or
         spec.options.delegateOperation.len > 0):
      fail(ecManifest, "custom backend has exec or delegate options")
    if spec.kind == bkExec and
        (spec.options.handler.len > 0 or spec.options.delegateCore.len > 0 or
         spec.options.delegateOperation.len > 0):
      fail(ecManifest, "exec backend has custom or delegate options")
    if spec.options.timeout.len == 0:
      fail(ecManifest, "backend requires timeout")
    result.timeoutMs = parseDurationMs(spec.options.timeout)
    result.sandbox = spec.options.sandbox
    result.user = if spec.options.user.len == 0: manifestAccount else: spec.options.user
    result.userIgnored = userMode
    result.writablePaths = spec.options.writablePaths
    result.network = spec.options.network
    result.environment = spec.options.environment
    result.workingDirectory = if spec.options.workingDirectory.len == 0: "/"
                              else: spec.options.workingDirectory
    let sandboxApplicable = info.operationClass != ocMutating and
      (spec.kind == bkCustom or spec.options.execMode == emOneshot)
    if sandboxApplicable and result.sandbox.isNone:
      fail(ecManifest, "sandbox is required for this operation")
    if not sandboxApplicable and result.sandbox.isSome:
      fail(ecManifest, "sandbox is forbidden for this operation")
    if (result.writablePaths.len > 0 or result.network) and
        (result.sandbox.isNone or not result.sandbox.get):
      fail(ecManifest, "writable_paths and network require sandbox: true")
    if spec.kind == bkCustom:
      if spec.options.handler.len == 0: fail(ecManifest, "custom backend requires handler")
      result.handler = spec.options.handler
    else:
      if spec.options.executable.len == 0: fail(ecManifest, "exec backend requires executable")
      result.executable = spec.options.executable
      result.arguments = spec.options.arguments
      result.execMode = spec.options.execMode
      if info.name.startsWith("core.") and result.execMode == emPersistent:
        fail(ecManifest, "core operations cannot use persistent exec")

proc initCoreDispatchPlan*(name: string): CoreDispatchPlan =
  CoreDispatchPlan(name: name,
    operations: initTable[string, PlannedOperation]())

proc addOperation*(plan: var CoreDispatchPlan; info: OperationInfo;
                   backend: ResolvedBackend) =
  plan.operations[info.name] = PlannedOperation(core: plan.name,
    operation: info.name, info: info, backend: backend)

proc resolveDispatch*(cores: Table[string, CoreDispatchPlan]; core,
                      operation: string): DispatchPlan =
  ## Resolve only explicit entries. In particular, absence and `unsupported`
  ## never fall back to a native or different core.
  result.requestedCore = core
  result.requestedOperation = operation
  var currentCore = core
  var currentOp = operation
  var seen = initHashSet[string]()
  while true:
    let key = currentCore & "\x00" & currentOp
    if key in seen:
      fail(ecDelegation, "delegation cycle", currentCore, currentOp)
    seen.incl key
    if not cores.hasKey(currentCore):
      fail(if result.chain.len == 0: ecNotFound else: ecDelegation,
           "core is unavailable: " & currentCore, currentCore, currentOp)
    let cp = cores[currentCore]
    if not cp.operations.hasKey(currentOp):
      fail(if result.chain.len == 0: ecUnsupported else: ecDelegation,
           "operation is not supported", currentCore, currentOp)
    let candidate = cp.operations[currentOp]
    if candidate.backend.kind == bkUnsupported:
      fail(if result.chain.len == 0: ecUnsupported else: ecDelegation,
           "operation is explicitly unsupported", currentCore, currentOp)
    result.chain.add DelegationHop(core: currentCore, operation: currentOp)
    if candidate.backend.kind != bkDelegate:
      result.target = candidate
      return
    if result.chain.len > MaxDelegationHops:
      fail(ecDelegation, "delegation chain exceeds four hops", currentCore, currentOp)
    currentCore = candidate.backend.delegateCore
    currentOp = candidate.backend.delegateOperation

proc validateDelegations*(cores: Table[string, CoreDispatchPlan]) =
  ## Validate the entire enabled/loaded set, not merely paths exercised so far.
  for core, cp in cores:
    for operation, candidate in cp.operations:
      if candidate.backend.kind == bkDelegate:
        try: discard resolveDispatch(cores, core, operation)
        except DispatchError as e:
          if e.code == ecUnsupported or e.code == ecNotFound:
            fail(ecDelegation, e.msg, core, operation)
          raise

proc selectLock*(info: OperationInfo; core: string; unit = ""): LockSelection =
  ## Lock policy comes from the manifest-versioned operation registry.
  result.core = core
  result.unit = unit
  case info.lock
  of olNone: result.kind = lkNone
  of olCore: result.kind = lkCore
  of olLog: result.kind = lkLog
  of olUnit:
    if unit.len == 0:
      fail(ecManifest, "unit lock requires a unit", core, info.name)
    result.kind = lkUnit

proc initLockManager*(): LockManager =
  result.nextId = 1
  result.tickets = initTable[uint64, LockTicket]()
  result.coreHolders = initTable[string, uint64]()
  result.unitHolders = initTable[string, uint64]()
  result.logHolders = initTable[string, uint64]()

proc unitKey(s: LockSelection): string = s.core & "\x00" & s.unit

proc conflicts(manager: LockManager; selection: LockSelection): bool =
  case selection.kind
  of lkNone: false
  of lkLog: manager.logHolders.hasKey(selection.core)
  of lkCore:
    if manager.coreHolders.hasKey(selection.core): return true
    for ticket in manager.tickets.values:
      if ticket.state == rsRunning and ticket.selection.kind == lkUnit and
          ticket.selection.core == selection.core: return true
    false
  of lkUnit:
    manager.coreHolders.hasKey(selection.core) or
      manager.unitHolders.hasKey(unitKey(selection))

proc hasCoreBarrier(manager: LockManager; core: string): bool =
  for id in manager.waiting:
    if manager.tickets.hasKey(id):
      let ticket = manager.tickets[id]
      if ticket.state == rsWaiting and ticket.selection.kind == lkCore and
          ticket.selection.core == core:
        return true

proc markRunning(manager: var LockManager; id: uint64) =
  var ticket = manager.tickets[id]
  ticket.state = rsRunning
  manager.tickets[id] = ticket
  case ticket.selection.kind
  of lkNone: discard
  of lkCore: manager.coreHolders[ticket.selection.core] = id
  of lkUnit: manager.unitHolders[unitKey(ticket.selection)] = id
  of lkLog: manager.logHolders[ticket.selection.core] = id

proc acquire*(manager: var LockManager; selection: LockSelection;
              nowMs, deadlineMs: int64; persistentAdapter = false): LockTicket =
  if deadlineMs <= nowMs: fail(ecTimeout, "operation timed out while waiting")
  let id = manager.nextId
  inc manager.nextId
  result = LockTicket(id: id, selection: selection, deadlineMs: deadlineMs,
    state: rsWaiting, cancelStartedMs: -1, persistentAdapter: persistentAdapter)
  manager.tickets[id] = result
  if selection.kind == lkNone or
      (not manager.conflicts(selection) and
       not (selection.kind == lkUnit and manager.hasCoreBarrier(selection.core))):
    manager.markRunning(id)
  else:
    manager.waiting.add id
  result = manager.tickets[id]

proc promote(manager: var LockManager; nowMs: int64) =
  var kept: seq[uint64]
  var barrierCores = initHashSet[string]()
  for id in manager.waiting:
    var ticket = manager.tickets[id]
    if ticket.state != rsWaiting: continue
    if ticket.deadlineMs <= nowMs:
      ticket.state = rsTimedOut
      ticket.cancelStartedMs = -1   # nothing was started, nothing to escalate
      manager.tickets[id] = ticket
      manager.transitions.add LockTransition(id: id, state: rsTimedOut)
      continue
    # Once a core-wide waiter is blocked, later unit work for that core waits
    # too; this prevents an isolate/load request from starving.
    if ticket.selection.core in barrierCores:
      kept.add id
    elif manager.conflicts(ticket.selection):
      kept.add id
      if ticket.selection.kind == lkCore: barrierCores.incl ticket.selection.core
    else:
      manager.markRunning(id)
      manager.transitions.add LockTransition(id: id, state: rsRunning)
  manager.waiting = kept

proc releaseHeld(manager: var LockManager; ticket: LockTicket) =
  case ticket.selection.kind
  of lkNone: discard
  of lkCore:
    if manager.coreHolders.getOrDefault(ticket.selection.core) == ticket.id:
      manager.coreHolders.del(ticket.selection.core)
  of lkUnit:
    if manager.unitHolders.getOrDefault(unitKey(ticket.selection)) == ticket.id:
      manager.unitHolders.del(unitKey(ticket.selection))
  of lkLog:
    if manager.logHolders.getOrDefault(ticket.selection.core) == ticket.id:
      manager.logHolders.del(ticket.selection.core)

proc complete*(manager: var LockManager; id: uint64; nowMs: int64) =
  if not manager.tickets.hasKey(id): return
  var ticket = manager.tickets[id]
  if ticket.state in {rsRunning, rsTimedOut, rsCancelled}:
    manager.releaseHeld(ticket)
  if ticket.state in {rsRunning, rsWaiting}: ticket.state = rsCompleted
  manager.tickets[id] = ticket
  manager.promote(nowMs)

proc cancel*(manager: var LockManager; id: uint64; nowMs: int64): CancellationStep =
  if not manager.tickets.hasKey(id): return csNone
  var ticket = manager.tickets[id]
  if ticket.state notin {rsWaiting, rsRunning}: return csNone
  let wasRunning = ticket.state == rsRunning
  ticket.state = rsCancelled
  ticket.cancelStartedMs = (if wasRunning: nowMs else: -1)
  manager.tickets[id] = ticket
  if not wasRunning: manager.promote(nowMs)
  if not wasRunning: csNone
  elif ticket.persistentAdapter: csCancelPersistentAdapter
  else: csTerminateProcessGroup

proc advance*(manager: var LockManager; nowMs: int64): seq[(uint64, CancellationStep)] =
  ## Expire whole-operation deadlines and plan escalation after the grace time.
  for id, oldTicket in manager.tickets.mpairs:
    if oldTicket.state in {rsWaiting, rsRunning} and oldTicket.deadlineMs <= nowMs:
      let wasRunning = oldTicket.state == rsRunning
      oldTicket.state = rsTimedOut
      oldTicket.cancelStartedMs = (if wasRunning: nowMs else: -1)
      if not wasRunning:
        manager.transitions.add LockTransition(id: id, state: rsTimedOut)
      if wasRunning:
        result.add (id, if oldTicket.persistentAdapter: csCancelPersistentAdapter
                         else: csTerminateProcessGroup)
    elif oldTicket.state in {rsTimedOut, rsCancelled} and
        oldTicket.cancelStartedMs >= 0 and
        nowMs - oldTicket.cancelStartedMs >= CancellationGraceMs:
      result.add (id, if oldTicket.persistentAdapter: csKillPersistentAdapter
                       else: csKillProcessGroup)
      # Emit escalation at most once.
      oldTicket.cancelStartedMs = -1
  manager.promote(nowMs)

proc ticket*(manager: LockManager; id: uint64): LockTicket =
  if not manager.tickets.hasKey(id): fail(ecNotFound, "unknown lock ticket")
  manager.tickets[id]

proc takeTransitions*(manager: var LockManager): seq[LockTransition] =
  ## Hook for the runtime: tickets promoted to running or expired while
  ## waiting since the last call, in order.
  result = manager.transitions
  manager.transitions.setLen(0)

proc forget*(manager: var LockManager; id: uint64) =
  ## Drop a finished ticket's bookkeeping once its result has been reported.
  if manager.tickets.hasKey(id) and
      manager.tickets[id].state in {rsCompleted, rsTimedOut, rsCancelled}:
    manager.tickets.del(id)
