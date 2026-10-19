## Calls: one operation on one core, from admission (§19.3) and the native
## §11.6 locks to completion, and the nested waits for Jumpstart's own steps
## (`callSync`, `waitUntil`).
import std/[algorithm, deques, json, monotimes, options, os, posix, sets, strutils,
  tables]
import ../backends/[adapter, adapter_runtime, backend_runtime, extension_runtime, supervisor_runtime],
  ../manifest/[coredirs, discovery, manifest, modes, types],
  ./[control, control_transport, core_host, logging, server, shutdown, shutdown_linux],
  ../lifecycle/[dispatch, lifecycle, lifecycle_exec, routing, runtime_resources, state],
  ../native/native_api,
  ../sessions/[session_manager, sessions]
import jumpstartcore/[cgroups, environment, errors, names, peercred, protocol, reaper, registry]
import ../manifest/nameindex as nameidx
import ../lifecycle/resources as res
import jumpstartcore/registry_types as regtypes
import ./daemon_state

# ---------------------------------------------------------------------------
# Calls: one operation on one core (§11-§13, §19.3)

proc callKey*(core: string; klass: res.OperationClass; ticket: uint64): string =
  core & "\x00" & $ord(klass) & "\x00" & $ticket

proc finishCall*(d: Daemon; call: Call; r: CallResult)

proc nativeMutating*(call: Call): bool =
  call.plan.target.info.operationClass == regtypes.ocMutating

proc nativeActivation*(call: Call): bool =
  call.targetOp in ["unit.activate", "unit.deactivate"]

proc canStartNativeActivation*(d: Daemon): bool =
  ## Activation takes no §11.6 lock, but two of them never nest on one stack.
  for frame in d.frames:
    if frame == fkNativeActivation: return false
  true

proc releaseNativeLock*(d: Daemon; call: Call) =
  ## Give back the call's §11.6 lock (or its place in line).
  if call.lockTicket == 0: return
  let id = call.lockTicket
  call.lockTicket = 0
  try:
    if d.nativeLocks.ticket(id).state == rsWaiting: discard d.nativeLocks.cancel(id, nowMs())
    else: d.nativeLocks.complete(id, nowMs())
    d.nativeLocks.forget(id)
  except CatchableError: discard

proc backendName*(call: Call): string =
  if call.plan.target.backend.kind == dispatch.bkNative: "native"
  else: ($call.plan.target.backend.kind)[2 .. ^1].toLowerAscii

proc beginCall*(d: Daemon; call: Call; requestId: string) =
  ## §19.2: one start line per operation, with the request id.
  if call.logged or d.config.logger.isNil: return
  call.logged = true
  call.logId = if requestId.len > 0: requestId else: "call-" & $call.id
  try:
    call.scope = d.config.logger.beginOperation(call.core, call.logId,
      call.operation, call.unit, call.backendName)
  except CatchableError: discard

proc runNative*(d: Daemon; call: Call) =
  ## Execute a native operation synchronously. Mutating ones may run nested
  ## loop turns while serviceHandler waits for its processes.
  let mutating = call.nativeMutating
  let activation = call.nativeActivation
  d.beginCall(call, "")
  if mutating: d.frames.add(if activation: fkNativeActivation else: fkNativeMutating)
  d.nativeStack.add mutating
  call.state = clRunning
  var r: CallResult
  try:
    r = okResult(d.config.native.dispatch(call.targetOp, call.unit, call.args))
  except CoreError as e: r = errResult(e.code, e.msg)
  except CatchableError as e: r = errResult(uncodedErrorCode(e), e.msg)
  except Defect as e: r = errResult(ecBackend, "internal error: " & e.msg)
  finally:
    discard d.nativeStack.pop()
    if mutating: discard d.frames.pop()
    d.releaseNativeLock(call)
  d.finishCall(call, r)

proc nativePump*(d: Daemon) =
  ## serviceHandler's `ctx.pump`: a mutating native operation that waits
  ## keeps the whole daemon running; any other native call only drains the
  ## reaper.
  if d.nativeStack.len > 0 and d.nativeStack[^1] and not d.exitRequested:
    d.runOnce(0)
  else:
    try: discard d.reaper.drain()
    except CatchableError: discard

proc ensureStateDir*(d: Daemon; core: string) =
  ## §20.3 step 5: retried before each dispatch once filesystems are ready.
  if not d.filesystemsReady or not d.info.hasKey(core) or d.info[core].stateDirDone: return
  try: checkTrustedDirectory(d.config.paths.stateRoot, d.config.statePaths.trustedUid)
  except CatchableError as e:
    d.log(clError, core, "state directory root is not trusted: " & e.msg)
    return
  let created = d.host.createStateDirStep()(core)
  if created.ok:
    d.info[core].stateDirDone = true
    d.info[core].stateDirError = ""
  elif created.error.message != d.info[core].stateDirError:
    # §20.3 step 5: logged, retried when filesystems become ready and before
    # each dispatch; it never fails the core.
    d.info[core].stateDirError = created.error.message
    d.log(clWarn, core, "state directory not created (retried later): " &
      created.error.message)

proc execute*(d: Daemon; call: Call) =
  ## The call holds its §19.3 slot: run it.
  if call.native:
    if not call.nativeMutating:
      d.runNative(call)
      return
    # §11.6: mutating operations take the unit, core or log lock their
    # registry entry names and wait until it is free; activation takes none.
    # Native operations declare no timeout (§13.6), so the wait ends when the
    # lock is free or the client goes away.
    call.state = clNativeWait
    call.deadlineMs = 0
    try:
      let ticket = d.nativeLocks.acquire(
        selectLock(call.plan.target.info, call.target, call.unit), nowMs(), NoDeadline)
      call.lockTicket = ticket.id
    except CoreError as e:
      d.finishCall(call, errResult(e.code, e.msg))
      return
    d.nativeQueue.addLast call.id
    return
  try:
    d.ensureStateDir(call.target)
    let id = d.backend.dispatch(call.target, call.targetOp, call.unit, call.args, nowMs())
    call.requestId = id
    call.state = clRunning
    d.byRequest[id] = call.id
    d.beginCall(call, id)
  except CoreError as e: d.finishCall(call, errResult(e.code, e.msg))
  except CatchableError as e: d.finishCall(call, errResult(uncodedErrorCode(e), e.msg))

proc startCall*(d: Daemon; core, operation, unit: string; args: JsonNode;
               internal: bool; onDone: proc(r: CallResult) {.closure.};
               onEntry: proc(entry: JsonNode) {.closure.} = nil): Call =
  inc d.nextCall
  let call = Call(id: d.nextCall, core: core, operation: operation, unit: unit,
    args: if args.isNil: newJObject() else: args, internal: internal,
    onDone: onDone, onEntry: onEntry)
  d.calls[call.id] = call
  result = call
  try:
    let p = d.pos(core)
    if p < 0: raise coreError(ecNotFound, "core not found: " & core, core)
    let rt = d.registry.cores[p]
    if not internal:
      let ready = routingError(rt)
      if not ready.ok: raise coreError(ready.error.code, ready.error.message, core)
      if d.info.hasKey(core) and d.info[core].closed:
        raise coreError(ecCoreState, core & " is closed to new requests", core)
    elif not rt.state.isLoaded and rt.state != csUnloading:
      raise coreError(ecCoreState, core & " is not loaded", core)
    if not d.plans.hasKey(core): raise coreError(ecCoreState, core & " is not published", core)
    call.plan = resolveDispatch(d.plans, core, operation)
    call.target = call.plan.target.core
    call.targetOp = call.plan.target.operation
    if call.target != core:
      let target = d.stateOf(call.target)
      if not target.isLoaded and not (internal and target == csUnloading):
        raise coreError(ecDelegation, "delegation target " & call.target &
          " is not loaded", call.target)
    call.native = call.plan.target.backend.kind == dispatch.bkNative
    call.klass = res.classify(call.targetOp,
      call.plan.target.info.operationClass == regtypes.ocMutating)
    d.infoOf(core).activeCalls.incl call.id
    let admission = d.resources.admitOperation(call.target, call.klass)
    case admission.admission.kind
    of akRejected:
      raise coreError(ecLimit, "too many in-flight operations on " & call.target, call.target)
    of akQueued:
      call.ticket = admission.admission.ticket
      call.state = clQueued
      # §11.6: a queued request waits for its own timeout; native operations
      # declare none (§13.6) and wait until a slot is free.
      call.deadlineMs = if call.plan.target.backend.timeoutMs > 0:
        nowMs() + call.plan.target.backend.timeoutMs else: 0
      d.queuedCalls[callKey(call.target, call.klass, call.ticket)] = call.id
    of akAdmitted:
      call.admitted = true
      d.execute(call)
  except CoreError as e:
    d.finishCall(call, errResult(e.code, e.msg))
  except CatchableError as e:
    d.finishCall(call, errResult(uncodedErrorCode(e), e.msg))

proc finishCall*(d: Daemon; call: Call; r: CallResult) =
  if call.state == clDone: return
  call.state = clDone
  call.result = r
  d.releaseNativeLock(call)
  # §19.2: the completion line (and a start line first for an operation that
  # failed before it began).
  if not d.config.logger.isNil:
    try:
      d.beginCall(call, "")
      d.config.logger.finishOperation(call.scope,
        if r.ok: "ok" else: errorName(r.code))
    except CatchableError: discard
  d.calls.del(call.id)
  if call.requestId.len > 0: d.byRequest.del(call.requestId)
  if d.info.hasKey(call.core): d.info[call.core].activeCalls.excl call.id
  if call.admitted:
    call.admitted = false
    try:
      let promoted = d.resources.completeOperation(call.target, call.klass)
      if promoted.admission.kind == akAdmitted:
        let key = callKey(call.target, call.klass, promoted.admission.ticket)
        if d.queuedCalls.hasKey(key):
          let next = d.queuedCalls[key]
          d.queuedCalls.del(key)
          if d.calls.hasKey(next):
            d.calls[next].admitted = true
            d.readyCalls.addLast next
    except CatchableError: discard
  if not call.onDone.isNil:
    try: call.onDone(r)
    except CatchableError as e: d.log(clError, call.core, "completion handler failed: " & e.msg)

proc cancelCall*(d: Daemon; call: Call) =
  ## Client cancellation (§13.7, §14.5).
  case call.state
  of clQueued:
    discard d.resources.cancelQueuedOperation(call.target, call.klass, call.ticket)
    d.queuedCalls.del(callKey(call.target, call.klass, call.ticket))
    d.finishCall(call, errResult(ecCancelled, "operation cancelled"))
  of clNativeWait:
    var kept = initDeque[int]()
    for id in d.nativeQueue:
      if id != call.id: kept.addLast id
    d.nativeQueue = kept
    d.releaseNativeLock(call)
    d.finishCall(call, errResult(ecCancelled, "operation cancelled"))
  of clRunning:
    if call.requestId.len > 0: d.backend.cancel(call.requestId, nowMs())
    # A native operation cannot be interrupted; its result is discarded.
  else: discard

proc callSync*(d: Daemon; core, operation, unit: string; args: JsonNode;
              deadlineMs: int64 = 0): CallResult

proc waitUntil*(d: Daemon; done: proc(): bool {.closure.}; deadlineMs: int64): bool =
  ## Run nested loop turns until `done` or the deadline. Only synchronous
  ## steps use this (§20.3/§20.4 procedures, native waits, session start).
  while not done():
    # A shutdown request ends every wait of a lifecycle procedure that is
    # still running (§20.8 starts at once); the frames unwind and the
    # shutdown sequence itself, which may wait, then takes over.
    if d.shutdownRequested and not d.shutdownRunning: return false
    let now = nowMs()
    if deadlineMs > 0 and now >= deadlineMs: return false
    let slice = if deadlineMs > 0: int(min(int64(BusyPollMs), deadlineMs - now)) else: BusyPollMs
    d.runOnce(max(slice, 0))
  true

proc effectiveDeadline*(d: Daemon; deadlineMs: int64): int64 =
  if d.unloadDeadlineMs > 0 and (deadlineMs <= 0 or d.unloadDeadlineMs < deadlineMs):
    d.unloadDeadlineMs
  else: deadlineMs

proc outerFrameMayHoldNativeLock*(d: Daemon): bool =
  ## A native mutating operation below the current frame is suspended inside
  ## its own nested loop turns and may hold a §11.6 lock that only it can
  ## release: waiting for that lock from here could never end.
  for frame in d.frames:
    if frame == fkNativeMutating: return true

proc callSync*(d: Daemon; core, operation, unit: string; args: JsonNode;
              deadlineMs: int64 = 0): CallResult =
  ## Jumpstart's own request, waited for with nested loop turns. The
  ## operation's timeout bounds it; `deadlineMs` (and an unload deadline
  ## during shutdown) may bound it further.
  ##
  ## §11.6: a native mutating call takes the same unit/core/log lock as a
  ## client's and waits for it in the nested turns, so it never interleaves with
  ## another operation on that unit. The one exception is a call made while a
  ## native mutating operation is suspended further down this stack (the §20.8
  ## shutdown sequence can start inside one): that operation cannot finish until
  ## this frame returns, so waiting would deadlock, and the call runs at once,
  ## in the frame that needs it. A native wait with no deadline of its own is
  ## bounded by `NativeCallWaitMs`.
  var finished = false
  var outcome: CallResult
  let call = d.startCall(core, operation, unit, args, internal = true,
    proc(r: CallResult) =
      finished = true
      outcome = r)
  if call.state == clNativeWait and d.outerFrameMayHoldNativeLock():
    var kept = initDeque[int]()
    for id in d.nativeQueue:
      if id != call.id: kept.addLast id
    d.nativeQueue = kept
    d.releaseNativeLock(call)   # runs in the frame that needs it, without waiting
    d.runNative(call)
  var limit = deadlineMs
  if limit <= 0 and not finished and call.native and
      call.state in {clNativeWait, clQueued} and call.deadlineMs == 0:
    limit = nowMs() + NativeCallWaitMs
  let deadline = d.effectiveDeadline(limit)
  if not d.waitUntil(proc(): bool = finished, deadline):
    d.cancelCall(call)
    discard d.waitUntil(proc(): bool = finished, d.effectiveDeadline(nowMs() + CancelSettleMs))
    if not finished:
      return errResult(ecTimeout, operation & " did not finish in time")
  outcome
