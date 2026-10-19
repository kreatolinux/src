import std/[json, unittest]
import ../../jumpstart/cores/daemon/[control, server]

const GoodRequest = """{"client":{"name":"test","version":"1"},"users":{"action":"list"}}
"""

type Harness = ref object
  output: string
  closes: int

proc connection(s: ControlServer; h: Harness; now = 0'i64;
                uid = 1000'i64): ControlConnection =
  let writer: WriteHandler = proc(data: string) = h.output.add data
  let closer: CloseHandler = proc() = inc h.closes
  openControlConnection(s, PeerCredentials(uid: uid, gid: uid, pid: 42),
    now, writer, closer)

suite "event-driven control server":
  test "fragmented request dispatches through injected handler":
    var called = 0
    let s = newControlServer(
      proc(req: ControlRequest; token: CancellationToken; done: ResponseHandler) =
        inc called
        check req.kind == rkUsers
        check not token.isCancelled
        done(okResponse(%* {"count": 2})),
      proc(peer: PeerCredentials): bool = peer.uid == 1000)
    let h = Harness()
    let c = connection(s, h)
    c.feed(GoodRequest[0 .. 10], 1)
    check called == 0
    c.feed(GoodRequest[11 .. ^1], 2)
    check called == 1
    check h.closes == 1
    check parseControlResponse(h.output).status == rsOk
    check s.activeConnectionCount == 0

  test "peer validation and admission limit are enforced":
    let s = newControlServer(
      proc(req: ControlRequest; token: CancellationToken; done: ResponseHandler) = discard,
      proc(peer: PeerCredentials): bool = peer.uid == 7,
      maxConnections = 1)
    let denied = Harness()
    discard connection(s, denied, uid = 8)
    check parseControlResponse(denied.output).error.code == ecPermission
    let first = Harness()
    let c = connection(s, first, uid = 7)
    check s.activeConnectionCount == 1
    let excess = Harness()
    discard connection(s, excess, uid = 7)
    check parseControlResponse(excess.output).error.code == ecLimit
    c.disconnect()
    check s.activeConnectionCount == 0

  test "idle and oversized clients cannot stall the server":
    let s = newControlServer(
      proc(req: ControlRequest; token: CancellationToken; done: ResponseHandler) = discard,
      proc(peer: PeerCredentials): bool = true,
      frameLimit = 16, idleTimeoutMs = 10)
    let idle = Harness()
    let a = connection(s, idle)
    check not a.expireIdle(9)
    check a.expireIdle(10)
    check idle.output.len == 0
    let huge = Harness()
    let b = connection(s, huge)
    b.feed("12345678901234567", 0)
    check parseControlResponse(huge.output).error.code == ecProtocol

  test "parse and handler errors become responses":
    let s = newControlServer(
      proc(req: ControlRequest; token: CancellationToken; done: ResponseHandler) =
        raise newException(ValueError, "adapter failed"),
      proc(peer: PeerCredentials): bool = true)
    let malformed = Harness()
    connection(s, malformed).feed("{bad}\n", 0)
    let parseError = parseControlResponse(malformed.output)
    check parseError.status == rsError
    check parseError.error.code == ecProtocol
    let backend = Harness()
    connection(s, backend).feed(GoodRequest, 0)
    check parseControlResponse(backend.output).error.code == ecBackend
    # §18: a filesystem or socket error without a code is E_IO.
    let ioServer = newControlServer(
      proc(req: ControlRequest; token: CancellationToken; done: ResponseHandler) =
        raise newException(IOError, "socket closed"),
      proc(peer: PeerCredentials): bool = true)
    let ioFailure = Harness()
    connection(ioServer, ioFailure).feed(GoodRequest, 0)
    check parseControlResponse(ioFailure.output).error.code == ecIo

  test "disconnect cancels an in-flight request":
    var pending: CancellationToken
    var completion: ResponseHandler
    let s = newControlServer(
      proc(req: ControlRequest; token: CancellationToken; done: ResponseHandler) =
        pending = token
        completion = done,
      proc(peer: PeerCredentials): bool = true)
    let h = Harness()
    let c = connection(s, h)
    c.feed(GoodRequest, 0)
    check not pending.isCancelled
    c.disconnect()
    check pending.isCancelled
    completion(okResponse())
    check h.output.len == 0
    check h.closes == 1

  test "a complete request line is parsed before the buffer is reused":
    # Regression: parsing shared the input string buffer, so clearing the
    # connection buffer first erased the request and produced E_PROTOCOL.
    var seen = ""
    let s = newControlServer(
      proc(req: ControlRequest; token: CancellationToken; done: ResponseHandler) =
        seen = req.client.name
        done(okResponse()),
      proc(peer: PeerCredentials): bool = true)
    let h = Harness()
    let c = connection(s, h)
    c.feed(GoodRequest, 0)
    check seen == "test"
    check parseControlResponse(h.output).status == rsOk
