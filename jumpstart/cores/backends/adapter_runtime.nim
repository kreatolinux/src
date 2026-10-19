## Concrete non-blocking driver for adapters and Kongue runners (§17, §13.7).
##
## `adapter` is the deterministic policy machine (handshake, multiplexing,
## deadlines, cancellation, restart budget). This module executes its actions:
## it spawns processes through `spawn.nim` with the central reaper, performs
## descriptor I/O, signals process groups, applies per-core locks from
## `dispatch.LockManager` (§11.6), validates results against the registry
## (§16.3), and turns every request into exactly one `Completion` whose error
## code is the §18 code (an adapter-supplied code is preserved).
##
## Nothing here blocks except `waitFor`/`waitIdle`, which are conveniences for
## synchronous callers (`jumpctl cores run`, tests). The daemon's event loop
## registers `pollDescriptors` and calls `pump` and `advance`.
import std/[deques, json, monotimes, options, os, sets, strutils, tables]
import posix
import ./[adapter, backends], ../lifecycle/dispatch
import jumpstartcore/[errors, protocol, reaper, registry, spawn]
export adapter.AdapterActionKind, adapter.AdapterAction

type
  RuntimeEventKind* = enum
    rekAdapter, rekStdout, rekStderr, rekIoError, rekExit, rekLog
  RuntimeEvent* = object
    ## `rekStdout`/`rekStderr` are output lines to log at info/warn (§19.2);
    ## `rekExit` reports a process end (`status`) for logging (§17.6);
    ## `rekLog` is a Kongue `log LEVEL MESSAGE` (§16.3) for the core's log
    ## (§19.2), with `requestId`, `level` and `text`.
    kind*: RuntimeEventKind
    adapter*: string
    action*: AdapterAction
    text*: string
    level*: string
    requestId*: string
    status*: ChildStatus
  SpecProvider* = proc(): ProcessSpec {.closure.}
    ## Builds the process specification at every (re)start, so executables
    ## are opened and verified immediately before each spawn (§8.3). The
    ## runtime closes `executableFd` after spawning. May raise `CoreError`.
  Completion* = object
    requestId*, operation*: string
    ok*: bool
    value*: JsonNode                 ## result, with `item` events merged (§17.4)
    events*: seq[ProtocolMessage]    ## events in arrival order
    code*: CoreErrorCode
    detail*: string
  PendingExit = object
    adapter: string
    status: ChildStatus
  PendingRequest = object
    operation: string
    events: seq[ProtocolMessage]
    items: seq[ProtocolMessage]
    ticket: uint64                   # 0 = no lock
    role: CoreRole
    failure: Option[(CoreErrorCode, string)]
  QueuedStart = object
    requestId: string
    deadlineMs: int64
    start: proc(remainingMs: int64) {.closure.}
  LiveProcess = ref object
    child: SpawnedProcess
    inputOpen, closeRequested: bool
    outputOpen, stdoutOpen, stderrOpen: bool
    discardOversize: bool
    input: string
    inputOffset: int
    output: string
    stdoutBuffer: string
    stderrBuffer: string
  AdapterRuntime* = ref object
    manager*: AdapterManager
    reaper*: Reaper
    locks*: LockManager
    providers: Table[string, SpecProvider]
    live: Table[string, LiveProcess]
    exits: Deque[PendingExit]
    events: Deque[RuntimeEvent]
    pending: Table[string, PendingRequest]
    completions: OrderedTable[string, Completion]
    queued: Table[uint64, QueuedStart]
    lifecycleRuns: HashSet[string]   # `init`/`shutdown` runs: no registry result

proc monotonicMs*(): int64 =
  ## Monotonic milliseconds for `nowMs` arguments.
  getMonoTime().ticks div 1_000_000

proc initAdapterRuntime*(coreMode, jumpstartVersion: string;
                         reaper = newReaper()): AdapterRuntime =
  if reaper.isNil: raise newException(ValueError, "reaper is required")
  AdapterRuntime(manager: initAdapterManager(coreMode, jumpstartVersion),
    reaper: reaper, locks: initLockManager(),
    providers: initTable[string, SpecProvider](),
    live: initTable[string, LiveProcess](), exits: initDeque[PendingExit](),
    events: initDeque[RuntimeEvent](), pending: initTable[string, PendingRequest](),
    completions: initOrderedTable[string, Completion](),
    queued: initTable[uint64, QueuedStart](), lifecycleRuns: initHashSet[string]())

proc processSpec*(plan: ExecutionPlan; useDescriptor = true): ProcessSpec =
  ## Bridge a `backends` plan to the spawn contract. With `useDescriptor`,
  ## the plan's verified descriptor is executed (§8.3). Identity, sandbox and
  ## environment layering are the caller's (see `backend_runtime`).
  if not plan.spawn.protocolDescriptors:
    raise newException(ValueError, "backend plan requires protocol descriptors")
  result.executable = descriptorPath(plan.spawn.executable)
  if useDescriptor: result.executableFd = some(cint(descriptorHandle(plan.spawn.executable)))
  result.arguments = if plan.spawn.argv.len > 1: plan.spawn.argv[1 .. ^1] else: @[]
  for key, value in plan.spawn.environment: result.environment.add((key, value))
  result.workingDirectory = plan.spawn.workingDirectory
  result.protocol = true
  result.cgroupProcs = plan.spawn.controlGroup

proc setNonBlocking(fd: cint) =
  if fd < 0: return
  let flags = fcntl(fd, F_GETFL, 0)
  if flags < 0 or fcntl(fd, F_SETFL, flags or O_NONBLOCK) < 0:
    raiseOSError(osLastError())

proc closeInputNow(process: LiveProcess) =
  if process.inputOpen:
    closeFd(process.child.protocolWriteFd)
    process.inputOpen = false

proc closeAll(process: LiveProcess) =
  process.closeInputNow()
  if process.outputOpen: closeFd(process.child.protocolReadFd); process.outputOpen = false
  if process.stdoutOpen: closeFd(process.child.stdoutFd); process.stdoutOpen = false
  if process.stderrOpen: closeFd(process.child.stderrFd); process.stderrOpen = false

proc emit(runtime: AdapterRuntime; event: RuntimeEvent) = runtime.events.addLast(event)

proc ioError(runtime: AdapterRuntime; name, text: string) =
  runtime.emit(RuntimeEvent(kind: rekIoError, adapter: name, text: text))

proc signalGroup(runtime: AdapterRuntime; process: LiveProcess; signal: cint) =
  # Guarded by the reaper registration so a reused process group is never hit.
  discard runtime.reaper.signalChildGroup(process.child.pid, signal)

proc wouldBlock(): bool =
  let error = osLastError()
  error == OSErrorCode(EAGAIN) or error == OSErrorCode(EWOULDBLOCK)

proc flushInput(runtime: AdapterRuntime; name: string; process: LiveProcess) =
  while process.inputOpen and process.inputOffset < process.input.len:
    let count = write(process.child.protocolWriteFd,
      unsafeAddr process.input[process.inputOffset], process.input.len - process.inputOffset)
    if count > 0: process.inputOffset += int(count)
    elif count < 0 and osLastError() == OSErrorCode(EINTR): continue
    elif count < 0 and wouldBlock(): break
    else:
      process.closeInputNow()
      runtime.ioError(name, "adapter protocol write failed")
      break
  if process.inputOffset == process.input.len:
    process.input.setLen(0); process.inputOffset = 0
    if process.closeRequested: process.closeInputNow()

proc apply(runtime: AdapterRuntime; actions: openArray[AdapterAction]; nowMs: int64)

proc completeRequest(runtime: AdapterRuntime; completion: Completion) =
  if runtime.completions.hasKey(completion.requestId): return
  runtime.completions[completion.requestId] = completion

proc failPending(runtime: AdapterRuntime; id: string; code: CoreErrorCode; detail: string) =
  var operation = ""
  var events: seq[ProtocolMessage]
  if runtime.pending.hasKey(id):
    operation = runtime.pending[id].operation
    events = runtime.pending[id].events
  runtime.completeRequest(Completion(requestId: id, operation: operation,
    ok: false, code: code, detail: detail, events: events))

proc startQueued(runtime: AdapterRuntime; nowMs: int64) =
  for transition in runtime.locks.takeTransitions():
    if not runtime.queued.hasKey(transition.id): continue
    let queued = runtime.queued[transition.id]
    runtime.queued.del(transition.id)
    case transition.state
    of rsRunning:
      queued.start(max(1'i64, queued.deadlineMs - nowMs))
    of rsTimedOut:
      # §11.6: a waiting request waits until the lock is free or its own
      # timeout expires.
      runtime.failPending(queued.requestId, ecTimeout, "operation timed out waiting for its lock")
      runtime.pending.del(queued.requestId)
      runtime.locks.forget(transition.id)
    else: discard

proc release(runtime: AdapterRuntime; id: string; nowMs: int64) =
  if not runtime.pending.hasKey(id): return
  let ticket = runtime.pending[id].ticket
  runtime.pending.del(id)
  if ticket != 0:
    runtime.locks.complete(ticket, nowMs)
    runtime.locks.forget(ticket)
    runtime.startQueued(nowMs)

proc start(runtime: AdapterRuntime; name: string; nowMs: int64) =
  let base = name
  if not runtime.providers.hasKey(base):
    runtime.apply(runtime.manager.startFailed(name, ecInit,
      "no process specification for adapter", nowMs), nowMs)
    return
  var spec: ProcessSpec
  try:
    spec = runtime.providers[base]()
    let child = spawn.spawn(spec, runtime.reaper, owner = name,
      callback = proc(status: ChildStatus) =
        runtime.exits.addLast(PendingExit(adapter: name, status: status)))
    if spec.executableFd.isSome: closeFd(spec.executableFd.get)
    setNonBlocking(child.protocolWriteFd); setNonBlocking(child.protocolReadFd)
    setNonBlocking(child.stdoutFd); setNonBlocking(child.stderrFd)
    runtime.live[name] = LiveProcess(child: child, inputOpen: true,
      outputOpen: true, stdoutOpen: true, stderrOpen: true)
  except CoreError as error:
    if spec.executableFd.isSome: closeFd(spec.executableFd.get)
    runtime.apply(runtime.manager.startFailed(name, error.code, error.msg, nowMs), nowMs)
  except CatchableError as error:
    if spec.executableFd.isSome: closeFd(spec.executableFd.get)
    runtime.apply(runtime.manager.startFailed(name, ecInit, error.msg, nowMs), nowMs)

proc mergeItems(value: JsonNode; items: seq[ProtocolMessage]): JsonNode =
  ## §17.4: items are appended to the named field in the order received,
  ## before any elements the response itself contains.
  result = value.copy
  var byField = initOrderedTable[string, seq[JsonNode]]()
  for item in items: byField.mgetOrPut(item.field, @[]).add item.data
  for field, values in byField:
    var combined = newJArray()
    for v in values: combined.add v
    if result.hasKey(field):
      if result[field].kind != JArray:
        raise newException(ProtocolError, field & " is not a list")
      for v in result[field]: combined.add v
    result[field] = combined

proc onEvent(runtime: AdapterRuntime; action: AdapterAction) =
  if not runtime.pending.hasKey(action.requestId): return
  # Work on the table entry in place: copying it for every `item` event made
  # a read of N entries cost O(N^2). Nothing below inserts into `pending`.
  let pendingEntry = addr runtime.pending[action.requestId]
  template pending: untyped = pendingEntry[]
  if pending.failure.isSome: return
  let message = action.message
  try:
    let spec = findOperation(CurrentManifestVersion, pending.operation)
    if message.kind == pmEventItem:
      var listField = false
      if spec.isSome:
        for field in spec.get.results:
          if field.name == message.field and field.kind == vkObjectList: listField = true
          elif field.name == message.field and field.kind in {vkStringList, vkIntList}:
            listField = true
      if not listField:
        raise newException(ProtocolError, "item for a field that is not a list: " & message.field)
      if message.data.kind == JObject:
        validateObjectItem(pending.operation, message.field, message.data)
      pending.items.add message
    elif message.kind == pmEventEntry and pending.role == crRunner:
      # §16.1/§16.3: a runner reports `log` over descriptor 4. §17 has no
      # separate message for it, so the runner sends an `entry` payload
      # and it goes to the core's log (§19.2), never into the result.
      validateEntry(message.data)
      runtime.emit(RuntimeEvent(kind: rekLog, adapter: action.adapter,
        requestId: action.requestId, level: message.data["level"].getStr,
        text: message.data["message"].getStr))
      return
    elif message.kind == pmEventEntry:
      if spec.isSome and spec.get.operationClass != ocStreaming and pending.operation != "log.read":
        raise newException(ProtocolError, "entry event for a non-log operation")
      validateEntry(message.data)
    pending.events.add message
  except ProtocolError as error:
    pending.failure = some((ecProtocol, error.msg))

proc onResponse(runtime: AdapterRuntime; action: AdapterAction) =
  let id = action.requestId
  if not runtime.pending.hasKey(id): return
  let pending = runtime.pending[id]
  var completion = Completion(requestId: id, operation: pending.operation,
    events: pending.events)
  if pending.failure.isSome:
    (completion.code, completion.detail) = pending.failure.get
  elif action.response.kind == pmResponseOk:
    try:
      let value = mergeItems(action.response.result, pending.items)
      if id notin runtime.lifecycleRuns and
          findOperation(CurrentManifestVersion, pending.operation).isSome:
        validateResult(pending.operation, value)
      completion.ok = true
      completion.value = value
    except ProtocolError as error:
      completion.code = ecProtocol
      completion.detail = error.msg
  else:
    (completion.code, completion.detail) = responseFailure(action.response)
  runtime.completeRequest(completion)

proc apply(runtime: AdapterRuntime; actions: openArray[AdapterAction]; nowMs: int64) =
  for action in actions:
    runtime.emit(RuntimeEvent(kind: rekAdapter, adapter: action.adapter, action: action))
    case action.kind
    of aaStart:
      runtime.start(action.adapter, nowMs)
    of aaSend:
      if runtime.live.hasKey(action.adapter):
        let process = runtime.live[action.adapter]
        try:
          process.input.add encodeLine(action.message)
          runtime.flushInput(action.adapter, process)
        except ProtocolError as error:
          runtime.ioError(action.adapter, error.msg)
    of aaCloseInput:
      if runtime.live.hasKey(action.adapter):
        let process = runtime.live[action.adapter]
        process.closeRequested = true
        runtime.flushInput(action.adapter, process)
    of aaTerminateGroup:
      if runtime.live.hasKey(action.adapter):
        runtime.signalGroup(runtime.live[action.adapter], SIGTERM)
    of aaKillGroup:
      if runtime.live.hasKey(action.adapter):
        runtime.signalGroup(runtime.live[action.adapter], SIGKILL)
    of aaEvent: runtime.onEvent(action)
    of aaResponse: runtime.onResponse(action)
    of aaFailure:
      runtime.failPending(action.requestId, action.errorCode, action.detail)
    of aaSettled:
      runtime.release(action.requestId, nowMs)
    else: discard

proc addPending(runtime: AdapterRuntime; request: ProtocolMessage; ticket: uint64;
                role: CoreRole) =
  if runtime.pending.hasKey(request.id) or runtime.completions.hasKey(request.id):
    raise newException(ValueError, "duplicate request id: " & request.id)
  runtime.pending[request.id] = PendingRequest(operation: request.op, ticket: ticket,
    role: role)

proc gate(runtime: AdapterRuntime; request: ProtocolMessage; lock: LockSelection;
          nowMs, timeoutMs: int64; start: proc(remainingMs: int64) {.closure.};
          role = crAdapter) =
  ## Take the §11.6 lock, then start. A request that must wait is queued and
  ## started when the lock is granted, with the rest of its own timeout.
  if timeoutMs <= 0: raise newException(ValueError, "operations need their timeout")
  if lock.kind == lkNone:
    runtime.addPending(request, 0, role)
    start(timeoutMs)
    return
  let ticket = runtime.locks.acquire(lock, nowMs, nowMs + timeoutMs)
  runtime.addPending(request, ticket.id, role)
  if ticket.state == rsRunning:
    start(timeoutMs)
  else:
    runtime.queued[ticket.id] = QueuedStart(requestId: request.id,
      deadlineMs: nowMs + timeoutMs, start: start)

proc registerPersistent*(runtime: AdapterRuntime; name, core: string;
                         operations: openArray[string]; provider: SpecProvider) =
  if provider.isNil: raise newException(ValueError, "adapter needs a process specification")
  runtime.manager.registerPersistent(name, core, operations)
  runtime.providers[name] = provider

proc registerPersistent*(runtime: AdapterRuntime; name, core: string;
                         operations: openArray[string]; spec: ProcessSpec) =
  ## Static specification (no verified descriptor reopened per start).
  if not spec.protocol: raise newException(ValueError, "adapter needs protocol pipes")
  let fixed = spec
  runtime.registerPersistent(name, core, operations, proc(): ProcessSpec = fixed)

proc startPersistent*(runtime: AdapterRuntime; name: string; nowMs: int64) =
  runtime.apply(runtime.manager.startPersistent(name, nowMs), nowMs)

proc submitPersistent*(runtime: AdapterRuntime; name: string; request: ProtocolMessage;
                       nowMs, timeoutMs: int64; lock = LockSelection(kind: lkNone)) =
  let rt = runtime
  runtime.gate(request, lock, nowMs, timeoutMs, proc(remainingMs: int64) =
    let now = monotonicMs()
    rt.apply(rt.manager.requestPersistent(name, request, now, remainingMs), now))

proc submitOneshot*(runtime: AdapterRuntime; baseName, core: string;
                    operations: openArray[string]; request: ProtocolMessage;
                    provider: SpecProvider; nowMs, timeoutMs: int64;
                    lock = LockSelection(kind: lkNone); role = crAdapter) =
  ## One process per request; `role = crRunner` for Kongue runners.
  let rt = runtime
  let ops = @operations
  runtime.gate(request, lock, nowMs, timeoutMs, proc(remainingMs: int64) =
    let now = monotonicMs()
    var actions: seq[AdapterAction]
    try:
      actions = rt.manager.requestOneshot(baseName, core, ops, request, now,
        remainingMs, role)
    except ValueError as error:
      rt.failPending(request.id, ecProtocol, error.msg)
      rt.release(request.id, now)
      return
    for action in actions:
      if action.kind == aaStart: rt.providers[action.adapter] = provider
    rt.apply(actions, now), role)

proc submitRunner*(runtime: AdapterRuntime; baseName, core: string;
                   request: ProtocolMessage; provider: SpecProvider;
                   nowMs, timeoutMs: int64; lock = LockSelection(kind: lkNone)) =
  runtime.submitOneshot(baseName, core, [], request, provider, nowMs, timeoutMs,
    lock, crRunner)

proc submitLifecycle*(runtime: AdapterRuntime; baseName, core: string;
                      request: ProtocolMessage; provider: SpecProvider;
                      nowMs, timeoutMs: int64) =
  ## `init`/`shutdown` in a Kongue runner (§20.3 step 6, §20.4 step 4): no
  ## lock, and the result is not checked against the operation registry
  ## because these functions have no registry entry (§16.2).
  runtime.lifecycleRuns.incl request.id
  runtime.submitOneshot(baseName, core, [], request, provider, nowMs, timeoutMs,
    LockSelection(kind: lkNone), crRunner)

proc requestPersistent*(runtime: AdapterRuntime; name: string;
                        request: ProtocolMessage; nowMs: int64; timeoutMs = 0'i64) =
  ## Compatibility entry without locks. Prefer `submitPersistent`.
  runtime.addPending(request, 0, crAdapter)
  runtime.apply(runtime.manager.requestPersistent(name, request, nowMs, timeoutMs), nowMs)

proc requestOneshot*(runtime: AdapterRuntime; baseName, core: string;
                     operations: openArray[string]; request: ProtocolMessage;
                     spec: ProcessSpec; nowMs, timeoutMs: int64): string =
  ## Compatibility entry without locks. Returns the instance name.
  runtime.addPending(request, 0, crAdapter)
  let actions = runtime.manager.requestOneshot(baseName, core, operations,
    request, nowMs, timeoutMs)
  let fixed = spec
  for action in actions:
    if action.kind == aaStart:
      result = action.adapter
      runtime.providers[result] = proc(): ProcessSpec = fixed
      break
  runtime.apply(actions, nowMs)

proc cancel*(runtime: AdapterRuntime; requestId: string; nowMs: int64) =
  ## Client cancellation (§13.7). A request still waiting for its lock ends
  ## with `E_CANCELLED` immediately.
  if runtime.pending.hasKey(requestId):
    let ticket = runtime.pending[requestId].ticket
    if ticket != 0 and runtime.queued.hasKey(ticket):
      runtime.queued.del(ticket)
      discard runtime.locks.cancel(ticket, nowMs)
      runtime.failPending(requestId, ecCancelled, "operation cancelled")
      runtime.pending.del(requestId)
      runtime.locks.forget(ticket)
      runtime.startQueued(nowMs)
      return
  runtime.apply(runtime.manager.cancel(requestId, nowMs), nowMs)

proc unload*(runtime: AdapterRuntime; name: string; nowMs: int64) =
  runtime.apply(runtime.manager.unload(name, nowMs), nowMs)

proc advance*(runtime: AdapterRuntime; nowMs: int64) =
  ## Drive deadlines: operation timeouts, handshake timeouts, §13.7
  ## escalation, and lock-wait expiry.
  runtime.apply(runtime.manager.advance(nowMs), nowMs)
  discard runtime.locks.advance(nowMs)  # process escalation is the adapter manager's
  runtime.startQueued(nowMs)

const
  MaxReadPerPass = 64 * 1024
    ## One descriptor is read at most this many bytes per pump, so a process
    ## that floods a pipe cannot hold PID 1 or grow its buffers (§19.2).
  MaxLogLineBytes = 64 * 1024
    ## Standard output and error are logged line by line; a longer line is
    ## split here, so an unterminated stream never accumulates (same limit as
    ## logging.ProcessLogLineLimit).

proc readAvailable(fd: cint; open: var bool; buffer: var string): int {.discardable.} =
  ## Returns the number of bytes read.
  var bytes: array[8192, char]
  var total = 0
  while open and total < MaxReadPerPass:
    let count = read(fd, addr bytes[0], bytes.len)
    if count > 0:
      total += int(count)
      let start = buffer.len
      buffer.setLen(start + int(count))
      copyMem(addr buffer[start], addr bytes[0], int(count))
    elif count == 0:
      closeFd(fd); open = false; break
    elif osLastError() == OSErrorCode(EINTR): continue
    elif wouldBlock(): break
    else:
      closeFd(fd); open = false; break
  result = total

proc emitLines(runtime: AdapterRuntime; name: string; buffer: var string;
               kind: RuntimeEventKind; final = false) =
  ## §19.2: stdout is logged at info and stderr at warn by the consumer.
  while true:
    let newline = buffer.find('\n')
    if newline < 0 or newline > MaxLogLineBytes:
      if buffer.len > MaxLogLineBytes:
        # An over-long line is split into records instead of buffered.
        runtime.emit(RuntimeEvent(kind: kind, adapter: name,
          text: buffer[0 ..< MaxLogLineBytes]))
        buffer.delete(0 ..< MaxLogLineBytes)
        continue
      if newline < 0: break
    runtime.emit(RuntimeEvent(kind: kind, adapter: name, text: buffer[0 ..< newline]))
    buffer.delete(0 .. newline)
  if final and buffer.len > 0:
    runtime.emit(RuntimeEvent(kind: kind, adapter: name, text: buffer))
    buffer.setLen(0)

proc parseProtocol(runtime: AdapterRuntime; name: string; process: LiveProcess;
                   nowMs: int64) =
  while true:
    let newline = process.output.find('\n')
    if newline < 0:
      if process.output.len > MaxProtocolLineBytes and not process.discardOversize:
        # §17.6: oversize lines fail the affected requests with E_PROTOCOL.
        runtime.apply(runtime.manager.receiveLine(name, process.output, nowMs), nowMs)
        process.discardOversize = true
      if process.discardOversize: process.output.setLen(0)
      break
    if process.discardOversize:
      process.output.delete(0 .. newline)
      process.discardOversize = false
      continue
    let line = process.output[0 .. newline]
    process.output.delete(0 .. newline)
    runtime.apply(runtime.manager.receiveLine(name, line, nowMs), nowMs)

proc exitCode(status: ChildStatus): int =
  case status.kind
  of cekExited: status.code
  of cekSignaled: 128 + status.code
  else: 1

proc pump*(runtime: AdapterRuntime; nowMs: int64) =
  ## Perform all immediately available non-blocking I/O and deliver reaper
  ## exits.
  if runtime.reaper.sigChldPending(): discard runtime.reaper.drainWakeup()
  else: discard runtime.reaper.drain()
  var names: seq[string]
  for name in runtime.live.keys: names.add name
  for name in names:
    if not runtime.live.hasKey(name): continue
    let process = runtime.live[name]
    runtime.flushInput(name, process)
    readAvailable(process.child.protocolReadFd, process.outputOpen, process.output)
    runtime.parseProtocol(name, process, nowMs)
    readAvailable(process.child.stdoutFd, process.stdoutOpen, process.stdoutBuffer)
    runtime.emitLines(name, process.stdoutBuffer, rekStdout)
    readAvailable(process.child.stderrFd, process.stderrOpen, process.stderrBuffer)
    runtime.emitLines(name, process.stderrBuffer, rekStderr)
  while runtime.exits.len != 0:
    let pending = runtime.exits.popFirst()
    if runtime.live.hasKey(pending.adapter):
      let process = runtime.live[pending.adapter]
      # Everything the process wrote before exiting is already in the pipes:
      # read it in bounded passes (bounded overall, a descendant may still
      # hold a pipe open and keep writing).
      var got = 1
      var rounds = 0
      while got > 0 and rounds < 16:
        inc rounds
        got = readAvailable(process.child.protocolReadFd, process.outputOpen, process.output)
        runtime.parseProtocol(pending.adapter, process, nowMs)
        got += readAvailable(process.child.stdoutFd, process.stdoutOpen, process.stdoutBuffer)
        runtime.emitLines(pending.adapter, process.stdoutBuffer, rekStdout)
        got += readAvailable(process.child.stderrFd, process.stderrOpen, process.stderrBuffer)
        runtime.emitLines(pending.adapter, process.stderrBuffer, rekStderr)
      runtime.emitLines(pending.adapter, process.stdoutBuffer, rekStdout, final = true)
      runtime.emitLines(pending.adapter, process.stderrBuffer, rekStderr, final = true)
      process.closeAll()
      runtime.live.del(pending.adapter)
    runtime.emit(RuntimeEvent(kind: rekExit, adapter: pending.adapter,
      status: pending.status))
    runtime.apply(runtime.manager.processExited(pending.adapter,
      pending.status.exitCode, nowMs), nowMs)
    runtime.manager.forgetOneshot(pending.adapter)
    if runtime.providers.hasKey(pending.adapter) and
        not runtime.manager.persistent(pending.adapter):
      runtime.providers.del(pending.adapter)

proc pollDescriptors*(runtime: AdapterRuntime): seq[cint] =
  ## Descriptors the event loop should poll for readability (plus the
  ## reaper's wakeup descriptor).
  result.add runtime.reaper.wakeupFd
  for process in runtime.live.values:
    if process.outputOpen: result.add process.child.protocolReadFd
    if process.stdoutOpen: result.add process.child.stdoutFd
    if process.stderrOpen: result.add process.child.stderrFd

proc waitReadable(runtime: AdapterRuntime; timeoutMs: int) =
  var fds: seq[TPollfd]
  for fd in runtime.pollDescriptors():
    if fd >= 0: fds.add TPollfd(fd: fd, events: POLLIN)
  for process in runtime.live.values:
    if process.inputOpen and process.input.len > process.inputOffset:
      fds.add TPollfd(fd: process.child.protocolWriteFd, events: POLLOUT)
  if fds.len == 0:
    discard poll(nil, 0, cint(timeoutMs))
  else:
    discard poll(addr fds[0], Tnfds(fds.len), cint(timeoutMs))

const WaitSliceMs = 10
  ## Poll granularity of the synchronous helpers. SIGCHLD may be unhandled in
  ## synchronous callers, so exits are also noticed by periodic draining. This
  ## is not an operation timing: every deadline comes from the manifest or §13.7.

proc waitSlice*(runtime: AdapterRuntime) =
  ## One poll slice for synchronous callers that drive `pump`/`advance`
  ## themselves (`jumpctl cores run`, which prints events between slices).
  runtime.waitReadable(WaitSliceMs)

proc hasCompletion*(runtime: AdapterRuntime; requestId: string): bool =
  runtime.completions.hasKey(requestId)

proc takeCompletion*(runtime: AdapterRuntime; requestId: string): Option[Completion] =
  if runtime.completions.hasKey(requestId):
    result = some(runtime.completions[requestId])
    runtime.completions.del(requestId)
    runtime.lifecycleRuns.excl requestId

proc takeCompletions*(runtime: AdapterRuntime): seq[Completion] =
  for id, completion in runtime.completions:
    result.add completion
    runtime.lifecycleRuns.excl id
  runtime.completions.clear()

proc writeDescriptors*(runtime: AdapterRuntime): seq[cint] =
  ## Protocol pipes with unsent input, to poll for writability.
  for process in runtime.live.values:
    if process.inputOpen and process.input.len > process.inputOffset:
      result.add process.child.protocolWriteFd

proc pendingCount*(runtime: AdapterRuntime): int =
  ## Requests that have not produced their completion yet.
  runtime.pending.len

proc isPending*(runtime: AdapterRuntime; requestId: string): bool =
  runtime.pending.hasKey(requestId)

proc waitFor*(runtime: AdapterRuntime; requestId: string): Completion =
  ## Drive the runtime until `requestId` completes. The request's own
  ## deadline (set at submission) bounds the wait.
  while true:
    let now = monotonicMs()
    runtime.pump(now)
    runtime.advance(now)
    let done = runtime.takeCompletion(requestId)
    if done.isSome: return done.get
    if not runtime.pending.hasKey(requestId):
      raise newException(KeyError, "unknown request id: " & requestId)
    runtime.waitReadable(WaitSliceMs)

proc liveCount*(runtime: AdapterRuntime): int = runtime.live.len

proc waitIdle*(runtime: AdapterRuntime) =
  ## Drive post-response cleanup (§17.6: close fd 3, wait 5 s, then §13.7)
  ## until no process remains.
  while runtime.live.len != 0 or runtime.exits.len != 0:
    let now = monotonicMs()
    runtime.pump(now)
    runtime.advance(now)
    if runtime.live.len != 0: runtime.waitReadable(WaitSliceMs)

proc hasEvents*(runtime: AdapterRuntime): bool = runtime.events.len != 0
proc nextEvent*(runtime: AdapterRuntime): RuntimeEvent = runtime.events.popFirst()
proc running*(runtime: AdapterRuntime; name: string): bool = runtime.live.hasKey(name)
proc processId*(runtime: AdapterRuntime; name: string): Pid =
  if runtime.live.hasKey(name): runtime.live[name].child.pid else: Pid(-1)

proc liveProcesses*(runtime: AdapterRuntime): seq[(string, Pid)] =
  ## Every live adapter or runner process with its instance name.
  for name, process in runtime.live: result.add (name, process.child.pid)
