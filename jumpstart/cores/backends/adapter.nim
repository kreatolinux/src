## Transport/process-independent adapter manager state machine.
##
## The caller owns processes, descriptors and clocks.  It feeds process events to
## this module and executes the returned actions.  `nowMs` is a monotonic clock;
## consequently tests and non-POSIX transports need no timers or processes.
import std/[json, sets, tables]
import jumpstartcore/[errors, protocol]

const
  PersistentHandshakeMs* = 10_000'i64
    ## §17.2: a persistent adapter's hello reply must arrive within 10 seconds.
  AdapterGraceMs* = 5_000'i64
    ## §13.7 and §17.6: 5 seconds between closing fd 3 / SIGTERM / `cancel`
    ## and the next escalation step.
  RestartWindowMs* = 60_000'i64
    ## §17.6: at most 5 lazy restarts in 60 seconds.
  MaxRestartsPerWindow* = 5
  MaxNotificationsPerSecond* = 100
    ## §17.5, §19.3

type
  AdapterMode* = enum
    amOneshot, amPersistent
  AdapterState* = enum
    asStopped, asHandshaking, asReady, asClosing, asFailed, asDegraded
  AdapterActionKind* = enum
    aaStart,                 ## Start the process represented by the adapter.
    aaSend,                  ## Write message to descriptor 3.
    aaCloseInput,            ## Close descriptor 3.
    aaTerminateGroup,        ## SIGTERM equivalent for the process group.
    aaKillGroup,             ## SIGKILL equivalent for the process group.
    aaResponse,              ## A request completed (success or adapter error).
    aaFailure,               ## Jumpstart-generated request failure.
    aaEvent,                 ## Request event.
    aaNotification,          ## Accepted unsolicited state notification.
    aaNotificationDropped,   ## Rate-limit log hook.
    aaFilesystemsReady,      ## Accepted readiness indication.
    aaDegraded,              ## Core must transition to degraded.
    aaLog,                   ## Non-result process lifecycle warning.
    aaSettled                ## Request no longer occupies the process (release locks).

  AdapterAction* = object
    kind*: AdapterActionKind
    adapter*, requestId*: string
    message*: ProtocolMessage
    response*: ProtocolMessage
    errorCode*: CoreErrorCode
    detail*: string

  RequestRecord = object
    operation: string
    request: ProtocolMessage
    cancelled: bool
    reason: CoreErrorCode           # ecCancelled (client) or ecTimeout (§11.6)
    reported: bool                  # failure already delivered to the caller
    deadline: int64                 # whole-operation deadline; 0 = none
    cancelDeadline: int64

  AdapterProcess = ref object
    name, core: string
    mode: AdapterMode
    role: CoreRole
    operations: seq[string]
    state: AdapterState
    running: bool
    generation: uint64
    helloDeadline: int64
    requests: OrderedTable[string, RequestRecord]
    completed: HashSet[string]
    restartTimes: seq[int64]
    needsRestart: bool
    closeDeadline, killDeadline: int64
    terminating: bool
    responseSeen: bool              # oneshot only
    notificationTimes: seq[int64]
    notifyDropReported: bool

  AdapterManager* = object
    coreMode*, jumpstartVersion*: string
    adapters: OrderedTable[string, AdapterProcess]
    ids: Table[string, string]       # request id -> adapter
    nextOneshot: uint64

proc initAdapterManager*(coreMode, jumpstartVersion: string): AdapterManager =
  result.coreMode = coreMode
  result.jumpstartVersion = jumpstartVersion
  result.adapters = initOrderedTable[string, AdapterProcess]()
  result.ids = initTable[string, string]()

proc action(kind: AdapterActionKind; p: AdapterProcess; id = ""): AdapterAction =
  AdapterAction(kind: kind, adapter: p.name, requestId: id)

proc failureAction(p: AdapterProcess; id: string; code: CoreErrorCode;
                   detail: string): AdapterAction =
  result = action(aaFailure, p, id)
  result.errorCode = code
  result.detail = detail

proc sendAction(p: AdapterProcess; msg: ProtocolMessage): AdapterAction =
  result = action(aaSend, p, msg.id)
  result.message = msg

proc hello(p: AdapterProcess; manager: AdapterManager): ProtocolMessage =
  helloOffer(p.role, p.core, manager.coreMode, manager.jumpstartVersion)

proc persistent*(manager: AdapterManager; name: string): bool =
  manager.adapters.hasKey(name) and manager.adapters[name].mode == amPersistent

proc state*(manager: AdapterManager; name: string): AdapterState =
  if not manager.adapters.hasKey(name): asStopped else: manager.adapters[name].state

proc inFlight*(manager: AdapterManager; name: string): seq[string] =
  if manager.adapters.hasKey(name):
    for id in manager.adapters[name].requests.keys: result.add id

proc registerPersistent*(manager: var AdapterManager; name, core: string;
                         operations: openArray[string]) =
  ## Registration is idempotent only for an identical definition.
  if manager.adapters.hasKey(name):
    let p = manager.adapters[name]
    if p.mode != amPersistent or p.core != core or p.operations != @operations:
      raise newException(ValueError, "conflicting persistent adapter: " & name)
    return
  manager.adapters[name] = AdapterProcess(name: name, core: core,
    mode: amPersistent, role: crAdapter, operations: @operations, state: asStopped,
    requests: initOrderedTable[string, RequestRecord](),
    completed: initHashSet[string]())

proc startProcess(p: AdapterProcess; manager: AdapterManager; nowMs,
                  handshakeMs: int64): seq[AdapterAction] =
  p.running = true
  p.state = asHandshaking
  inc p.generation
  p.helloDeadline = nowMs + handshakeMs
  p.terminating = false
  p.closeDeadline = 0
  p.killDeadline = 0
  p.responseSeen = false
  p.notificationTimes.setLen(0)
  p.notifyDropReported = false
  result.add action(aaStart, p)
  result.add sendAction(p, hello(p, manager))

proc startPersistent*(manager: var AdapterManager; name: string;
                      nowMs: int64): seq[AdapterAction] =
  ## Used during core load. Initial starts do not consume the restart budget.
  if not manager.adapters.hasKey(name):
    raise newException(KeyError, "unknown adapter: " & name)
  let p = manager.adapters[name]
  if p.mode != amPersistent: raise newException(ValueError, "not persistent")
  if p.state == asDegraded or p.running: return
  p.needsRestart = false
  result = startProcess(p, manager, nowMs, PersistentHandshakeMs)

proc removeId(manager: var AdapterManager; p: AdapterProcess; id: string;
              actions: var seq[AdapterAction]) =
  if p.requests.hasKey(id) or manager.ids.hasKey(id):
    actions.add action(aaSettled, p, id)
  p.requests.del(id)
  manager.ids.del(id)
  p.completed.incl id

proc failRequests(manager: var AdapterManager; p: AdapterProcess;
                  code: CoreErrorCode; detail: string): seq[AdapterAction] =
  var ids: seq[string]
  for id in p.requests.keys: ids.add id
  for id in ids:
    if not p.requests[id].reported:
      result.add failureAction(p, id, code, detail)
    manager.removeId(p, id, result)

proc pruneRestarts(p: AdapterProcess; nowMs: int64) =
  var kept: seq[int64]
  for at in p.restartTimes:
    if nowMs - at < RestartWindowMs: kept.add at
  p.restartTimes = kept

proc lazyRestart(manager: var AdapterManager; p: AdapterProcess;
                 nowMs: int64): seq[AdapterAction] =
  p.pruneRestarts(nowMs)
  if p.restartTimes.len >= MaxRestartsPerWindow:
    p.state = asDegraded
    p.needsRestart = false
    result.add action(aaDegraded, p)
    result[^1].errorCode = ecDegraded
    result[^1].detail = "persistent adapter exceeded 5 restarts in 60 seconds"
  else:
    p.restartTimes.add nowMs
    p.needsRestart = false
    result = startProcess(p, manager, nowMs, PersistentHandshakeMs)

proc queueRequest(manager: var AdapterManager; p: AdapterProcess;
                  request: ProtocolMessage; deadline: int64) =
  if request.kind != pmRequest:
    raise newException(ValueError, "adapter request must be a request message")
  if manager.ids.hasKey(request.id) or request.id in p.completed:
    raise newException(ValueError, "duplicate request id: " & request.id)
  p.requests[request.id] = RequestRecord(operation: request.op, request: request,
    deadline: deadline)
  manager.ids[request.id] = p.name

proc requestPersistent*(manager: var AdapterManager; name: string;
                        request: ProtocolMessage; nowMs: int64;
                        timeoutMs = 0'i64): seq[AdapterAction] =
  ## `timeoutMs` is the operation's `timeout` (§13.1, §11.6); it bounds the
  ## whole request including a lazy restart. 0 means the caller enforces it.
  if not manager.adapters.hasKey(name): raise newException(KeyError, "unknown adapter: " & name)
  let p = manager.adapters[name]
  if p.mode != amPersistent: raise newException(ValueError, "not persistent")
  if p.state == asDegraded:
    return @[failureAction(p, request.id, ecDegraded, "core is degraded")]
  if request.op notin p.operations:
    return @[failureAction(p, request.id, ecProtocol,
      "operation is not routed to this adapter: " & request.op)]
  manager.queueRequest(p, request, if timeoutMs > 0: nowMs + timeoutMs else: 0)
  if not p.running:
    result.add manager.lazyRestart(p, nowMs)
    if p.state == asDegraded:
      # The request was queued before the budget check.
      result.add manager.failRequests(p, ecDegraded, "core is degraded")
      return
  if p.state == asReady: result.add sendAction(p, request)

proc requestOneshot*(manager: var AdapterManager; adapterName, core: string;
                     operations: openArray[string]; request: ProtocolMessage;
                     nowMs, timeoutMs: int64; role = crAdapter): seq[AdapterAction] =
  ## One process per request (§17.6). The hello reply must arrive within the
  ## operation's timeout (§17.2), and the timeout bounds the whole operation.
  ## Runners (`role = crRunner`) follow the same pattern and omit operations.
  if manager.ids.hasKey(request.id): raise newException(ValueError, "duplicate request id: " & request.id)
  if timeoutMs <= 0: raise newException(ValueError, "oneshot requests need the operation timeout")
  if role == crSupervisor: raise newException(ValueError, "supervisors receive no requests")
  if role == crRunner and request.function.len == 0:
    raise newException(ValueError, "runner requests carry the function to run")
  inc manager.nextOneshot
  let name = adapterName & "#" & $manager.nextOneshot
  let p = AdapterProcess(name: name, core: core, mode: amOneshot, role: role,
    operations: @operations, state: asStopped,
    requests: initOrderedTable[string, RequestRecord](),
    completed: initHashSet[string]())
  manager.adapters[name] = p
  if role == crAdapter and request.op notin p.operations:
    manager.adapters.del(name)
    return @[failureAction(p, request.id, ecProtocol,
      "operation is not routed to this adapter: " & request.op)]
  manager.queueRequest(p, request, nowMs + timeoutMs)
  result = startProcess(p, manager, nowMs, timeoutMs)

proc requestRunner*(manager: var AdapterManager; runnerName, core: string;
                    request: ProtocolMessage; nowMs, timeoutMs: int64): seq[AdapterAction] =
  ## Kongue runner (§16.1): role `runner`, one request per process.
  manager.requestOneshot(runnerName, core, [], request, nowMs, timeoutMs, crRunner)

proc protocolFailure(manager: var AdapterManager; p: AdapterProcess;
                     detail: string; affectedId = ""): seq[AdapterAction] =
  if affectedId.len != 0 and p.requests.hasKey(affectedId):
    # The framing is still synchronized and the spec identifies the affected
    # request, so other multiplexed requests remain valid.
    if not p.requests[affectedId].reported:
      result.add failureAction(p, affectedId, ecProtocol, detail)
    manager.removeId(p, affectedId, result)
    return
  result.add manager.failRequests(p, ecProtocol, detail)
  if p.running:
    result.add action(aaTerminateGroup, p)
    p.terminating = true
    p.killDeadline = 0                 # set by caller's clock in receive
  p.state = asFailed
  if p.mode == amPersistent: p.needsRestart = true

proc receive*(manager: var AdapterManager; name: string; message: ProtocolMessage;
              nowMs: int64): seq[AdapterAction] =
  if not manager.adapters.hasKey(name): return
  let p = manager.adapters[name]
  if not p.running: return manager.protocolFailure(p, "message from stopped adapter")

  if p.state == asHandshaking:
    if message.kind != pmHelloReply:
      result = manager.protocolFailure(p, "expected adapter hello")
      p.killDeadline = nowMs + AdapterGraceMs
      return
    try: validateHandshake(hello(p, manager), message, p.operations)
    except ProtocolError as e:
      result = manager.protocolFailure(p, e.msg)
      p.killDeadline = nowMs + AdapterGraceMs
      return
    p.state = asReady
    p.helloDeadline = 0
    for _, request in p.requests:
      # A request cancelled during startup is already being torn down
      # (oneshot: SIGTERM) or was dropped (persistent); never send it.
      if not request.cancelled: result.add sendAction(p, request.request)
    return

  case message.kind
  of pmResponseOk, pmResponseError:
    if not p.requests.hasKey(message.id):
      result = manager.protocolFailure(p,
        if message.id in p.completed: "duplicate response id: " & message.id
        else: "unknown response id: " & message.id)
      p.killDeadline = nowMs + AdapterGraceMs
      return
    if p.requests[message.id].reported:
      # The caller already received E_TIMEOUT (§11.6); the late response only
      # frees the request.
      result.add action(aaLog, p, message.id)
      result[^1].detail = "response after the operation timed out"
    else:
      result.add action(aaResponse, p, message.id)
      result[^1].response = message
    manager.removeId(p, message.id, result)
    if p.mode == amOneshot:
      p.responseSeen = true
      p.state = asClosing
      p.closeDeadline = nowMs + AdapterGraceMs
      result.add action(aaCloseInput, p)
  of pmEventEntry, pmEventItem:
    if not p.requests.hasKey(message.id):
      result = manager.protocolFailure(p, "unknown event id: " & message.id)
      p.killDeadline = nowMs + AdapterGraceMs
    else:
      result.add action(aaEvent, p, message.id)
      result[^1].message = message
  of pmNotify:
    var first = 0
    while first < p.notificationTimes.len and
        nowMs - p.notificationTimes[first] >= 1_000:
      inc first
    if first != 0: p.notificationTimes = p.notificationTimes[first .. ^1]
    if p.notificationTimes.len < MaxNotificationsPerSecond:
      p.notificationTimes.add nowMs
      p.notifyDropReported = false
      result.add action(aaNotification, p)
      result[^1].message = message
    elif not p.notifyDropReported:
      p.notifyDropReported = true
      result.add action(aaNotificationDropped, p)
      result[^1].detail = "more than 100 notifications in one second"
  of pmFilesystemsReady:
    result.add action(aaFilesystemsReady, p)
  else:
    result = manager.protocolFailure(p, "unexpected adapter message")
    p.killDeadline = nowMs + AdapterGraceMs

proc receiveLine*(manager: var AdapterManager; name, line: string;
                  nowMs: int64): seq[AdapterAction] =
  ## Invalid input fails one request when a usable id is present, otherwise all.
  try:
    return manager.receive(name, parseLine(line), nowMs)
  except ProtocolError as e:
    if not manager.adapters.hasKey(name): return
    var id = ""
    try:
      let node = parseJson(line)
      if node.kind == JObject and node.hasKey("id") and node["id"].kind == JString:
        id = node["id"].getStr
    except CatchableError: discard
    result = manager.protocolFailure(manager.adapters[name], e.msg, id)
    if manager.adapters[name].state == asFailed:
      manager.adapters[name].killDeadline = nowMs + AdapterGraceMs

proc beginCancel(manager: var AdapterManager; p: AdapterProcess; requestId: string;
                 reason: CoreErrorCode; nowMs: int64): seq[AdapterAction] =
  ## §13.7 step 1: `cancel` to a ready persistent adapter, otherwise SIGTERM
  ## to the process group. Step 3 (SIGKILL) follows from `advance`.
  var request = p.requests[requestId]
  if request.cancelled: return
  request.cancelled = true
  request.reason = reason
  request.cancelDeadline = nowMs + AdapterGraceMs
  if reason == ecTimeout and not request.reported:
    # §11.6: on expiry Jumpstart cancels the operation and returns E_TIMEOUT.
    request.reported = true
    result.add failureAction(p, requestId, ecTimeout, "operation timed out")
  p.requests[requestId] = request
  if p.mode == amPersistent and p.running and p.state == asReady:
    result.add sendAction(p, protocol.cancel(requestId))
  elif p.running:
    if p.mode == amPersistent:
      # Not ready yet: the request has not been sent, so nothing in the
      # adapter knows about it. Drop it now.
      if not request.reported:
        result.add failureAction(p, requestId, reason,
          if reason == ecTimeout: "operation timed out" else: "operation cancelled")
      manager.removeId(p, requestId, result)
    else:
      result.add action(aaTerminateGroup, p, requestId)
      p.terminating = true
  else:
    if not request.reported:
      result.add failureAction(p, requestId, reason,
        if reason == ecTimeout: "operation timed out" else: "operation cancelled")
    manager.removeId(p, requestId, result)

proc cancel*(manager: var AdapterManager; requestId: string;
             nowMs: int64): seq[AdapterAction] =
  ## Client cancellation (§13.7). The adapter's own response, normally
  ## `E_CANCELLED`, is reported when it arrives (§17.3).
  if not manager.ids.hasKey(requestId): return
  let p = manager.adapters[manager.ids[requestId]]
  manager.beginCancel(p, requestId, ecCancelled, nowMs)

proc processExited*(manager: var AdapterManager; name: string; exitCode: int;
                    nowMs: int64): seq[AdapterAction] =
  if not manager.adapters.hasKey(name): return
  let p = manager.adapters[name]
  p.running = false
  p.helloDeadline = 0; p.closeDeadline = 0; p.killDeadline = 0
  if p.mode == amOneshot and p.responseSeen:
    if exitCode != 0:
      result.add action(aaLog, p)
      result[^1].detail = "oneshot adapter exited non-zero after its response"
    p.state = asStopped
  else:
    var ids: seq[string]
    for id in p.requests.keys: ids.add id
    for id in ids:
      let record = p.requests[id]
      let code = if record.cancelled: record.reason else: ecBackend
      let detail = if code == ecCancelled: "operation cancelled"
                   elif code == ecTimeout: "operation timed out"
                   else: "adapter exited before response"
      if not record.reported: result.add failureAction(p, id, code, detail)
      manager.removeId(p, id, result)
    p.state = asFailed
    if p.mode == amPersistent: p.needsRestart = true

proc startFailed*(manager: var AdapterManager; name: string; code: CoreErrorCode;
                  detail: string; nowMs: int64): seq[AdapterAction] =
  ## The process could not be started (verification, credentials, sandbox,
  ## cgroup). Its requests fail with that code, never as a generic exit.
  if not manager.adapters.hasKey(name): return
  let p = manager.adapters[name]
  p.running = false
  p.helloDeadline = 0; p.closeDeadline = 0; p.killDeadline = 0
  result.add manager.failRequests(p, code, detail)
  result.add action(aaLog, p)
  result[^1].errorCode = code
  result[^1].detail = "process start failed: " & detail
  p.state = asFailed
  if p.mode == amPersistent: p.needsRestart = true

proc forgetOneshot*(manager: var AdapterManager; name: string) =
  ## Drop a finished oneshot instance (after its process exited).
  if manager.adapters.hasKey(name) and manager.adapters[name].mode == amOneshot and
      not manager.adapters[name].running and manager.adapters[name].requests.len == 0:
    manager.adapters.del(name)

proc running*(manager: AdapterManager; name: string): bool =
  manager.adapters.hasKey(name) and manager.adapters[name].running

proc unload*(manager: var AdapterManager; name: string;
             nowMs: int64): seq[AdapterAction] =
  if not manager.adapters.hasKey(name): return
  let p = manager.adapters[name]
  result.add manager.failRequests(p, ecCancelled, "adapter unloaded")
  p.needsRestart = false
  if p.running:
    p.state = asClosing
    p.closeDeadline = nowMs + AdapterGraceMs
    result.add action(aaCloseInput, p)
  else: p.state = asStopped

proc advance*(manager: var AdapterManager; nowMs: int64): seq[AdapterAction] =
  ## Drive handshake, close and cancellation deadlines. Each edge fires once.
  for _, p in manager.adapters.mpairs:
    var expired: seq[string]
    for id, request in p.requests:
      if not request.cancelled and request.deadline != 0 and nowMs >= request.deadline:
        expired.add id
    for id in expired:
      if p.requests.hasKey(id): result.add manager.beginCancel(p, id, ecTimeout, nowMs)

    if p.running and p.state == asHandshaking and p.helloDeadline != 0 and nowMs >= p.helloDeadline:
      p.helloDeadline = 0
      # §17.2 bounds the hello reply by a timeout; missing it is E_TIMEOUT.
      result.add manager.failRequests(p, ecTimeout, "adapter handshake timed out")
      result.add action(aaLog, p)
      result[^1].errorCode = ecTimeout
      result[^1].detail = "adapter handshake timed out"
      result.add action(aaTerminateGroup, p)
      p.state = asFailed; p.terminating = true
      p.killDeadline = nowMs + AdapterGraceMs
      if p.mode == amPersistent: p.needsRestart = true

    var killForCancellation = false
    for _, request in p.requests:
      if request.cancelled and request.cancelDeadline != 0 and nowMs >= request.cancelDeadline:
        killForCancellation = true
    if killForCancellation and p.running:
      result.add action(aaKillGroup, p)
      p.terminating = true
      p.killDeadline = 0
      # Killing a persistent process also loses its other multiplexed work.
      # The cancelled operation retains E_CANCELLED; peers get E_BACKEND.
      var ids: seq[string]
      for id in p.requests.keys: ids.add id
      for id in ids:
        let record = p.requests[id]
        let code = if record.cancelled: record.reason else: ecBackend
        let detail = if record.cancelled: "adapter did not acknowledge cancellation"
                     else: "persistent adapter killed during cancellation"
        if not record.reported: result.add failureAction(p, id, code, detail)
        manager.removeId(p, id, result)
      if p.mode == amPersistent:
        p.state = asFailed; p.needsRestart = true

    if p.running and p.closeDeadline != 0 and nowMs >= p.closeDeadline:
      p.closeDeadline = 0
      result.add action(aaTerminateGroup, p)
      p.terminating = true
      p.killDeadline = nowMs + AdapterGraceMs
    elif p.running and p.killDeadline != 0 and nowMs >= p.killDeadline:
      p.killDeadline = 0
      result.add action(aaKillGroup, p)

proc restartCount*(manager: var AdapterManager; name: string;
                   nowMs: int64): int =
  if not manager.adapters.hasKey(name): return 0
  let p = manager.adapters[name]
  p.pruneRestarts(nowMs)
  p.restartTimes.len
