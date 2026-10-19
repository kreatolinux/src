## The adapter end of the exec protocol (jumpstart-cores §17) for cores
## written in Nim, so they need not re-implement it.
##
## An `AdapterSession` owns descriptors 3 (requests in) and 4 (responses and
## events out). A core registers one handler per operation it serves and calls
## `serve`, which
##
## - answers the `hello` offer with `operations` equal to the registered set
##   (§17.2);
## - runs each request through its handler and sends exactly one `response`
##   (§17.3): the validated result, or an error whose code is the `CoreError`
##   code raised by the handler (`E_BACKEND` for any other exception);
## - validates results with the registry before sending them, so a bug in an
##   adapter surfaces as `E_PROTOCOL` in its own response (§16.3);
## - reads `cancel` messages while a handler runs: `RequestContext.cancelled`
##   and `checkpoint` observe them, and a request cancelled before it started
##   is answered with `E_CANCELLED` without running;
## - exits 0 once descriptor 3 reaches EOF and queued requests are answered.
##
## `serve` runs one handler at a time. A core that multiplexes requests keeps
## its own event loop and uses the building blocks directly: `handshake`,
## `LineReader` from `jsonlines`, `send`, `emitItem`, `emitEntry` and the
## protocol constructors.
import std/[algorithm, deques, json, sets, tables, times]
import ./[errors, jsonlines, protocol]

type
  OperationHandler* = proc(ctx: RequestContext): JsonNode {.closure.}
    ## Returns the result object of the operation. Raise `CoreError` (see
    ## `newCoreError`) to fail the request with a specific code.
  RequestContext* = ref object
    session: AdapterSession
    id*, op*, unit*, function*: string
    args*: JsonNode
    deadline*: Time
    cancelRequested: bool
  AdapterSession* = ref object
    role*: CoreRole
    offer*: ProtocolMessage
      ## The `hello` offer received by `handshake`.
    inputFd*, outputFd*: cint
    reader: LineReader
    handlers: Table[string, OperationHandler]
    queue: Deque[ProtocolMessage]
    cancelledQueued: HashSet[string]
    active: RequestContext

const
  DefaultSoftDeadlineMarginMs* = 2_000'i64

proc failure(message: string) {.noreturn.} =
  var e = newException(ProtocolError, message)
  e.code = ecProtocol
  e.message = message
  raise e

proc newAdapterSession*(role = crAdapter; inputFd = 3.cint; outputFd = 4.cint): AdapterSession =
  ## `role` other than `crAdapter` is only useful with `handshake`, for a
  ## supervisor that replies to its `hello` (§17.2) and then runs its own loop.
  AdapterSession(role: role, inputFd: inputFd, outputFd: outputFd,
    reader: newLineReader(inputFd), handlers: initTable[string, OperationHandler](),
    queue: initDeque[ProtocolMessage](), cancelledQueued: initHashSet[string]())

proc handle*(session: AdapterSession; operation: string; handler: OperationHandler) =
  ## Register the handler of one operation. The registered set is what the
  ## hello reply declares, so it must equal the operations the manifest routes
  ## to this executable.
  session.handlers[operation] = handler

proc operations*(session: AdapterSession): seq[string] =
  for name in session.handlers.keys: result.add name
  result.sort()

proc send*(session: AdapterSession; message: ProtocolMessage) =
  writeAllFd(session.outputFd, encodeLine(message))

proc notify*(session: AdapterSession; unit, state: string; detail = "") =
  ## §17.5 unit state notification.
  session.send(notification(unit, state, detail))

proc filesystemsReady*(session: AdapterSession) =
  ## §17.5; ignored by Jumpstart in user mode.
  session.send(protocol.filesystemsReady())

proc accept(session: AdapterSession; message: ProtocolMessage) =
  ## Queue a request, or record a cancellation of the active or a queued one.
  case message.kind
  of pmRequest: session.queue.addLast message
  of pmCancel:
    if not session.active.isNil and session.active.id == message.id:
      session.active.cancelRequested = true
    else:
      for queued in session.queue:
        if queued.id == message.id:
          session.cancelledQueued.incl message.id
          break
  else: failure("unexpected message from Jumpstart: " & $message.kind)

proc readMessage(session: AdapterSession): bool =
  ## Block for one message and handle it. False at EOF.
  var line: string
  if not session.reader.readLine(line): return false
  session.accept(parseLine(line))
  true

proc handshake*(session: AdapterSession): ProtocolMessage =
  ## Read the `hello` offer and reply with the session's role and registered
  ## operations (§17.2). The offer must name this role and offer
  ## `jumpstart-core/1`; otherwise `ProtocolError` is raised and nothing is
  ## sent. Returns the offer (core name, mode, Jumpstart version).
  var line: string
  if not session.reader.readLine(line): failure("unexpected protocol EOF before hello")
  let offer = parseLine(line)
  let ops = if session.role == crAdapter: session.operations else: @[]
  let reply = helloReply(session.role, ops)
  validateHandshake(offer, reply, ops)
  session.send(reply)
  session.offer = offer
  offer

proc remainingMs*(ctx: RequestContext; now = getTime()): int64 =
  ## Milliseconds until the request's deadline (negative when past).
  (ctx.deadline - now).inMilliseconds

proc softDeadline*(ctx: RequestContext;
                   marginMs = DefaultSoftDeadlineMarginMs): Time =
  ## A point `marginMs` before the deadline, for operations that return their
  ## current state instead of failing when a job is still running.
  ctx.deadline - initDuration(milliseconds = marginMs)

proc cancelled*(ctx: RequestContext): bool =
  ## Whether Jumpstart cancelled this request. Looks at descriptor 3 without
  ## blocking, so a handler that works for a long time should call it (or
  ## `checkpoint`) regularly.
  let session = ctx.session
  var line: string
  while true:
    while session.reader.nextLine(line): session.accept(parseLine(line))
    if ctx.cancelRequested or not session.reader.fill(0): break
  ctx.cancelRequested

proc checkpoint*(ctx: RequestContext) =
  ## Raise `E_CANCELLED` after a `cancel` message and `E_TIMEOUT` once the
  ## deadline passed.
  if ctx.cancelled: raise newCoreError(ecCancelled, "request cancelled")
  if ctx.remainingMs <= 0: raise newCoreError(ecTimeout, "request deadline reached")

proc emitItem*(ctx: RequestContext; field: string; data: JsonNode) =
  ## §17.4 `item` event: one element of a list field of the result.
  validateObjectItem(ctx.op, field, data)
  ctx.session.send(itemEvent(ctx.id, field, data))

proc emitEntry*(ctx: RequestContext; data: JsonNode) =
  ## §17.4 `entry` event of `log.follow` and `log.read`-style streams.
  validateEntry(data)
  ctx.session.send(entryEvent(ctx.id, data))

proc failureResponse(id: string; code: CoreErrorCode; message: string): ProtocolMessage =
  errorResponse(id, errorName(code), if message.len == 0: errorName(code) else: message)

proc runRequest(session: AdapterSession; request: ProtocolMessage) =
  if request.id in session.cancelledQueued:
    session.cancelledQueued.excl request.id
    session.send(failureResponse(request.id, ecCancelled, "request cancelled before it started"))
    return
  let ctx = RequestContext(session: session, id: request.id, op: request.op,
    unit: request.unit, function: request.function, args: request.args,
    deadline: parseDeadline(request.deadline))
  session.active = ctx
  var response: ProtocolMessage
  try:
    if request.op notin session.handlers:
      raise newCoreError(ecUnsupported, "operation not implemented: " & request.op)
    if ctx.remainingMs <= 0:
      raise newCoreError(ecTimeout, "request deadline already passed")
    let value = session.handlers[request.op](ctx)
    validateResult(request.op, value)
    response = okResponse(request.id, value)
  except CoreError as e:
    if e.code == ecProtocol:
      stderr.writeLine("adapter: " & request.op & ": " & e.msg)
    response = failureResponse(request.id, e.code, e.msg)
  except CatchableError as e:
    response = failureResponse(request.id, ecBackend, e.msg)
  session.active = nil
  session.send(response)

proc serve*(session: AdapterSession): int =
  ## The complete adapter life cycle on the session's descriptors. Returns the
  ## process exit status: 0 after EOF on descriptor 3, 1 after a protocol or
  ## I/O failure that no request could carry (reported on standard error).
  try:
    discard session.handshake()
    var open = true
    while true:
      if session.queue.len > 0:
        session.runRequest(session.queue.popFirst())
      elif open:
        open = session.readMessage()
      else:
        break
    0
  except CoreError as e:
    stderr.writeLine("adapter: " & errorName(e.code) & ": " & e.msg)
    1
  except CatchableError as e:
    stderr.writeLine("adapter: " & e.msg)
    1
