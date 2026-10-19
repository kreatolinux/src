## Event-driven control-server core.
##
## This module deliberately owns no listening socket. The daemon's poll loop
## (`control_transport`) supplies bytes and the injected callbacks below. Keeping the transport edge this small makes peer
## credential lookup platform-specific while framing, admission, deadlines,
## parsing, and cancellation remain portable and testable.
import std/atomics
import ./control

const
  MaxControlConnections* = 256
  ControlFrameBytes* = 1024 * 1024
  ControlIdleTimeoutMs* = 10_000'i64

type
  PeerCredentials* = object
    ## Values obtained by the socket adapter (SO_PEERCRED/getpeereid).
    uid*, gid*: int64
    pid*: int64                 ## -1 when the platform does not expose it.
    pidfd*: int                 ## SO_PEERPIDFD, or -1 (§7.6 step 3)
    acceptedAt*: int64          ## acceptance time in clock ticks since boot

  CancellationToken* = ref object
    cancelled: Atomic[bool]

  PeerValidator* = proc(peer: PeerCredentials): bool {.closure.}
  WriteHandler* = proc(data: string) {.closure.}
  CloseHandler* = proc() {.closure.}
  ResponseHandler* = proc(response: ControlResponse) {.closure.}
  RequestHandler* = proc(request: ControlRequest;
                         cancellation: CancellationToken;
                         complete: ResponseHandler) {.closure.}
  CancelHook* = proc() {.closure.}
  RequestContext* = ref object
    ## One dispatched request: its peer, its cancellation, and the way back to
    ## the client (`emit` for events, `complete` for the single response).
    connection: ControlConnection
    peer*: PeerCredentials
    cancellation*: CancellationToken
    onCancel*: CancelHook       ## run once when the client goes away (§14.5)
    completed*: bool
  ContextHandler* = proc(request: ControlRequest; context: RequestContext) {.closure.}

  ControlServer* = ref object
    handler: ContextHandler
    validatePeer: PeerValidator
    maxConnections*: int
    frameLimit*: int
    idleTimeoutMs*: int64
    activeConnections: int

  ControlConnection* = ref object
    server: ControlServer
    peer*: PeerCredentials
    cancellation*: CancellationToken
    write: WriteHandler
    closeTransport: CloseHandler
    input: string
    deadlineMs*: int64
    admitted: bool
    requestDispatched*: bool
    closed*: bool
    context*: RequestContext

proc newCancellationToken(): CancellationToken =
  new(result)
  result.cancelled.store(false, moRelaxed)

proc isCancelled*(token: CancellationToken): bool =
  token.isNil or token.cancelled.load(moAcquire)

proc cancel*(token: CancellationToken) =
  if not token.isNil:
    token.cancelled.store(true, moRelease)

proc admitted*(connection: ControlConnection): bool =
  ## False once a connection was rejected (limit, credentials) or closed.
  not connection.isNil and connection.admitted

proc activeConnectionCount*(server: ControlServer): int =
  server.activeConnections

proc newControlServer*(handler: ContextHandler;
                       validatePeer: PeerValidator;
                       maxConnections = MaxControlConnections;
                       frameLimit = ControlFrameBytes;
                       idleTimeoutMs = ControlIdleTimeoutMs): ControlServer =
  if handler.isNil:
    raise newException(ValueError, "a request handler is required")
  if validatePeer.isNil:
    raise newException(ValueError, "a peer credential validator is required")
  if maxConnections <= 0 or maxConnections > MaxControlConnections:
    raise newException(ValueError, "connection limit must be in 1..256")
  if frameLimit <= 0 or frameLimit > ControlFrameBytes:
    raise newException(ValueError, "frame limit must be in 1..1 MiB")
  if idleTimeoutMs <= 0:
    raise newException(ValueError, "idle timeout must be positive")
  ControlServer(handler: handler, validatePeer: validatePeer,
    maxConnections: maxConnections, frameLimit: frameLimit,
    idleTimeoutMs: idleTimeoutMs)

proc complete*(context: RequestContext; response: ControlResponse)

proc newControlServer*(handler: RequestHandler;
                       validatePeer: PeerValidator;
                       maxConnections = MaxControlConnections;
                       frameLimit = ControlFrameBytes;
                       idleTimeoutMs = ControlIdleTimeoutMs): ControlServer =
  ## Handler form without events: `complete` sends the one response.
  if handler.isNil:
    raise newException(ValueError, "a request handler is required")
  newControlServer(proc(request: ControlRequest; context: RequestContext) =
      let ctx = context
      handler(request, context.cancellation,
        proc(response: ControlResponse) = ctx.complete(response)),
    validatePeer, maxConnections, frameLimit, idleTimeoutMs)

proc close(connection: ControlConnection; cancelRequest: bool) =
  if connection.isNil or connection.closed: return
  connection.closed = true
  if cancelRequest and connection.requestDispatched:
    cancel(connection.cancellation)
    let context = connection.context
    if not context.isNil and not context.completed and not context.onCancel.isNil:
      let hook = context.onCancel
      context.onCancel = nil
      try: hook()
      except CatchableError: discard   # cancellation must not poison the server
  if connection.admitted:
    connection.admitted = false
    dec connection.server.activeConnections
  try:
    connection.closeTransport()
  except CatchableError:
    discard                       # A failed close must not poison the server.

proc disconnect*(connection: ControlConnection) =
  ## Called by the adapter on EOF, hangup, or socket error.
  connection.close(true)

proc finish(connection: ControlConnection; response: ControlResponse) =
  if connection.closed or isCancelled(connection.cancellation): return
  var lines: seq[string]
  try:
    # §14.5: list fields of a result too large for one line go out as items.
    let (items, rest) = splitOversize(response, connection.server.frameLimit)
    for item in items: lines.add serializeControlEvent(item)
    lines.add serializeControlResponse(rest)
  except CoreError as exc:
    lines = @[serializeControlResponse(errorResponse(exc.code, exc.msg))]
  try:
    for line in lines: connection.write(line)
  except CatchableError:
    connection.close(true)
    return
  connection.close(false)

proc emit*(context: RequestContext; event: ControlEvent): bool =
  ## Send one `event` line before the response (§14.5, §17.4). False once the
  ## client is gone or the request has completed.
  if context.isNil or context.completed: return false
  let connection = context.connection
  if connection.closed or isCancelled(connection.cancellation): return false
  var line: string
  try: line = serializeControlEvent(event)
  except CoreError: return false
  try: connection.write(line)
  except CatchableError:
    connection.close(true)
    return false
  true

proc complete*(context: RequestContext; response: ControlResponse) =
  ## Send the single response and close the connection. Later calls are
  ## ignored.
  if context.isNil or context.completed: return
  context.completed = true
  context.connection.finish(response)

proc isCancelled*(context: RequestContext): bool =
  context.isNil or isCancelled(context.cancellation)

proc isClosed*(context: RequestContext): bool =
  context.isNil or context.connection.closed

proc reject(connection: ControlConnection; code: CoreErrorCode; message: string) =
  if connection.closed: return
  try:
    connection.write(serializeControlResponse(errorResponse(code, message)))
  except CatchableError:
    discard
  connection.close(false)

proc openControlConnection*(server: ControlServer; peer: PeerCredentials;
                            nowMs: int64; write: WriteHandler;
                            closeTransport: CloseHandler): ControlConnection =
  ## Admission is synchronous so a selector adapter never registers a rejected
  ## descriptor. `nowMs` must be monotonic.
  if server.isNil or write.isNil or closeTransport.isNil:
    raise newException(ValueError, "server and transport callbacks are required")
  result = ControlConnection(server: server, peer: peer,
    cancellation: newCancellationToken(), write: write,
    closeTransport: closeTransport, deadlineMs: nowMs + server.idleTimeoutMs)
  if server.activeConnections >= server.maxConnections:
    result.reject(ecLimit, "control connection limit reached")
    return
  var allowed = false
  try:
    allowed = server.validatePeer(peer)
  except CatchableError:
    allowed = false
  if not allowed:
    result.reject(ecPermission, "peer credentials rejected")
    return
  result.admitted = true
  inc server.activeConnections

proc expireIdle*(connection: ControlConnection; nowMs: int64): bool =
  ## Call from the selector timer pass. The 10 second deadline applies until a
  ## complete request line has arrived, not while an operation is executing.
  if connection.isNil or connection.closed or connection.requestDispatched:
    return false
  if nowMs >= connection.deadlineMs:
    connection.close(false)
    return true
  false

proc protocolFailure(connection: ControlConnection; message: string) =
  connection.reject(ecProtocol, message)

proc feed*(connection: ControlConnection; data: string; nowMs: int64) =
  ## Feed one nonblocking read. The adapter should call `disconnect` for EOF.
  if connection.isNil or connection.closed or connection.requestDispatched:
    return
  if connection.expireIdle(nowMs): return
  connection.input.add data
  let newline = connection.input.find('\n')
  if newline < 0:
    if connection.input.len > connection.server.frameLimit:
      connection.protocolFailure("control line exceeds 1 MiB")
    return
  if newline > connection.server.frameLimit:
    connection.protocolFailure("control line exceeds 1 MiB")
    return
  if newline + 1 != connection.input.len:
    connection.protocolFailure("connection must contain exactly one request line")
    return

  # Parse before clearing: `let line = connection.input` shares the string
  # payload, so clearing `connection.input` first would erase `line`.
  var request: ControlRequest
  try:
    request = parseControlRequest(connection.input)
  except ProtocolError as exc:
    connection.protocolFailure(exc.msg)
    return
  except CatchableError:
    connection.protocolFailure("invalid control request")
    return

  connection.input.setLen(0)
  connection.requestDispatched = true
  let context = RequestContext(connection: connection, peer: connection.peer,
    cancellation: connection.cancellation)
  connection.context = context
  try:
    connection.server.handler(request, context)
  except CoreError as exc:
    context.complete(errorResponse(exc.code, exc.msg))
  except CatchableError as exc:
    context.complete(errorResponse(uncodedErrorCode(exc), exc.msg))
