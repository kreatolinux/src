## The control socket transport's descriptor hygiene (§14.5, §7.6 step 3):
## the peer pidfd closes with its connection however the connection ends, a
## client that floods after its request is cut off, and EMFILE on accept
## pauses accepting instead of spinning the loop.
import std/[json, os, posix, sequtils, strutils, tempfiles, unittest]
import ../../jumpstart/cores/daemon/[control, control_transport, server]

let myUid = int64(getuid())

var clock: int64 = 0
var pidfds: seq[cint]          # every "pidfd" handed to the transport
var held: seq[RequestContext]  # requests the handler keeps open
var cancelled: int

proc isOpen(fd: cint): bool =
  fcntl(fd, F_GETFD) >= 0

proc newFixture(path: string; validUid = myUid): (ControlTransport, cint) =
  clock = 0
  pidfds.setLen(0)
  held.setLen(0)
  cancelled = 0
  let listenFd = cint(socket(AF_UNIX, SOCK_STREAM, 0))
  var address: Sockaddr_un
  address.sun_family = TSa_Family(AF_UNIX)
  copyMem(addr address.sun_path[0], unsafeAddr path[0], path.len)
  doAssert bindSocket(SocketHandle(listenFd), cast[ptr SockAddr](addr address),
    SockLen(sizeof(address))) == 0
  doAssert listen(SocketHandle(listenFd), 16) == 0
  let handler = proc(request: ControlRequest; context: RequestContext) =
    context.onCancel = proc() = inc cancelled
    held.add context
  let validator = proc(peer: PeerCredentials): bool = peer.uid == validUid
  let server = newControlServer(handler, validator)
  let lookup = proc(fd: cint): PeerCredentials =
    let pidfd = dup(0)           # stands in for SO_PEERPIDFD
    pidfds.add pidfd
    PeerCredentials(uid: myUid, gid: -1, pid: -1, pidfd: int(pidfd))
  let transport = newControlTransport(listenFd, server, proc(): int64 = clock, lookup)
  (transport, listenFd)

proc connectClient(path: string): cint =
  result = cint(socket(AF_UNIX, SOCK_STREAM, 0))
  var address: Sockaddr_un
  address.sun_family = TSa_Family(AF_UNIX)
  copyMem(addr address.sun_path[0], unsafeAddr path[0], path.len)
  doAssert connect(SocketHandle(result), cast[ptr SockAddr](addr address),
    SockLen(sizeof(address))) == 0

proc writeAll(fd: cint; text: string) =
  var offset = 0
  while offset < text.len:
    let n = posix.send(SocketHandle(fd), unsafeAddr text[offset], text.len - offset, 0)
    if n <= 0: break
    offset += n

proc turn(transport: ControlTransport) =
  ## One poll turn over the transport's descriptors.
  var fds: seq[TPollfd]
  transport.pollSet(fds)
  if fds.len == 0: return
  discard poll(addr fds[0], Tnfds(fds.len), 50)
  for pfd in fds:
    if pfd.revents != 0: transport.handle(pfd.fd, pfd.revents)

proc turns(transport: ControlTransport; count: int) =
  for i in 0 ..< count: transport.turn()

const Request = """{"client":{"name":"t","version":"2.0.0"},"core":{"action":"status"}}""" & "\n"

suite "control transport":
  test "the peer pidfd closes when the client disconnects before its request":
    let dir = createTempDir("jst-", "")
    defer: removeDir(dir)
    let path = dir / "s"
    let (transport, listenFd) = newFixture(path)
    defer: transport.close()
    let client = connectClient(path)
    transport.turns(2)
    check pidfds.len == 1
    check pidfds[0].isOpen
    check transport.connectionCount == 1
    discard posix.close(client)
    transport.turns(3)
    check transport.connectionCount == 0
    check not pidfds[0].isOpen
    discard listenFd

  test "the peer pidfd closes when the idle timeout expires":
    let dir = createTempDir("jst-", "")
    defer: removeDir(dir)
    let path = dir / "s"
    let (transport, _) = newFixture(path)
    defer: transport.close()
    let client = connectClient(path)
    defer: discard posix.close(client)
    transport.turns(2)
    check pidfds[0].isOpen
    clock = ControlIdleTimeoutMs + 1
    transport.expire(clock)
    transport.turns(2)
    check transport.connectionCount == 0
    check not pidfds[0].isOpen

  test "a finished connection whose reply is never read is expired":
    let dir = createTempDir("jst-", "")
    defer: removeDir(dir)
    let path = dir / "s"
    let (transport, _) = newFixture(path)
    defer: transport.close()
    let client = connectClient(path)
    defer: discard posix.close(client)
    transport.turns(2)
    client.writeAll(Request)
    transport.turns(3)
    check held.len == 1
    # A reply far larger than the socket buffers, which the client never reads.
    held[0].complete(okResponse(%*{"pad": newSeq[string](3000).mapIt('x'.repeat(1000))}))
    transport.turns(3)
    check transport.connectionCount == 1          # still draining: output pending
    clock = ClosingExpireMs - 1
    transport.expire(clock)
    check transport.connectionCount == 1
    clock = ClosingExpireMs + 1
    transport.expire(clock)
    check transport.connectionCount == 0
    check not pidfds[0].isOpen

  test "the peer pidfd closes after a framing failure and after a rejected peer":
    let dir = createTempDir("jst-", "")
    defer: removeDir(dir)
    let path = dir / "s"
    block malformed:
      let (transport, _) = newFixture(path)
      defer: transport.close()
      let client = connectClient(path)
      defer: discard posix.close(client)
      transport.turns(2)
      client.writeAll("{not json}\n")
      transport.turns(4)
      check transport.connectionCount == 0
      check not pidfds[0].isOpen
    removeFile(path)
    block rejected:
      let (transport, _) = newFixture(path, validUid = myUid + 1)
      defer: transport.close()
      let client = connectClient(path)
      defer: discard posix.close(client)
      transport.turns(4)
      check transport.connectionCount == 0
      check not pidfds[0].isOpen

  test "the pidfd stays valid while a request is in flight and closes when it ends":
    let dir = createTempDir("jst-", "")
    defer: removeDir(dir)
    let path = dir / "s"
    let (transport, _) = newFixture(path)
    defer: transport.close()
    let client = connectClient(path)
    defer: discard posix.close(client)
    transport.turns(2)
    client.writeAll(Request)
    transport.turns(3)
    check held.len == 1
    check held[0].peer.pidfd == int(pidfds[0])
    check pidfds[0].isOpen                    # a parked session request still has it
    held[0].complete(okResponse())
    transport.turns(3)
    check not pidfds[0].isOpen

  test "a client that floods after its request is disconnected and its request cancelled":
    let dir = createTempDir("jst-", "")
    defer: removeDir(dir)
    let path = dir / "s"
    let (transport, _) = newFixture(path)
    defer: transport.close()
    let client = connectClient(path)
    defer: discard posix.close(client)
    transport.turns(2)
    client.writeAll(Request)
    transport.turns(2)
    check held.len == 1
    let flood = newString(512 * 1024)
    discard fcntl(client, F_SETFL, fcntl(client, F_GETFL) or O_NONBLOCK)
    for i in 0 ..< 20:
      client.writeAll(flood)
      transport.turns(1)
    check cancelled == 1
    check transport.connectionCount == 0
    check not pidfds[0].isOpen

  test "EMFILE on accept pauses accepting instead of spinning":
    let dir = createTempDir("jst-", "")
    defer: removeDir(dir)
    let path = dir / "s"
    let (transport, listenFd) = newFixture(path)
    defer: transport.close()
    let client = connectClient(path)
    defer: discard posix.close(client)
    var limit: RLimit
    doAssert getrlimit(RLIMIT_NOFILE, limit) == 0
    var saved = limit
    let probe = dup(0)
    discard posix.close(probe)
    limit.rlim_cur = clong(probe)             # the next descriptor is refused
    doAssert setrlimit(RLIMIT_NOFILE, limit) == 0
    transport.handle(listenFd, POLLIN)
    doAssert setrlimit(RLIMIT_NOFILE, saved) == 0
    check transport.connectionCount == 0
    var fds: seq[TPollfd]
    transport.pollSet(fds)
    check fds.len == 0                        # the listener is not polled meanwhile
    clock = 1000
    transport.pollSet(fds)
    check fds.len == 1
    # Accepting works again once descriptors are free (whether the refused
    # connection survived in the backlog depends on the kernel).
    let second = connectClient(path)
    defer: discard posix.close(second)
    transport.handle(listenFd, POLLIN)
    check transport.connectionCount >= 1
