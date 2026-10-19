## Non-blocking Unix-socket transport for the control server (§14.5).
##
## The daemon's poll loop owns every descriptor: `pollSet` contributes the
## listening socket and the client connections, and `handle` performs the
## accept, read and write that poll reported ready. Nothing here blocks, so a
## slow or silent client can never stall PID 1. Output is buffered per
## connection and flushed on writability; a client that stops reading while
## more than `MaxBufferedOutput` bytes are pending is disconnected (which
## cancels its request).
import std/[posix, tables]
import ./server

const
  MaxBufferedOutput* = 8 * 1024 * 1024
  ReadChunk = 65536
  MaxReadsPerTurn = 16
    ## A client that keeps sending cannot hold the loop: one descriptor is
    ## read at most this many chunks per loop turn.
  MaxIgnoredAfterRequest = 65536
    ## Bytes a client may send after its one request line (§14.5) before it
    ## is treated as abusive and disconnected (which cancels its request).
  ClosingExpireMs* = 10_000'i64
    ## A finished connection whose reply the client does not read is dropped
    ## after this long, so its descriptor and up to `MaxBufferedOutput` bytes
    ## are not held forever.
  AcceptPauseMs = 100'i64
    ## EMFILE/ENFILE: the listener stays readable, so accepting pauses for
    ## this long instead of spinning the loop.

when defined(linux):
  let SendFlags = MSG_NOSIGNAL   # a var in std/posix, not a constant
else:
  const SendFlags = 0'i32        # SIGPIPE is ignored by the daemon

type
  PeerLookup* = proc(fd: cint): PeerCredentials {.closure.}
  TransportClock* = proc(): int64 {.closure.}
  Link = ref object
    fd: cint
    connection: ControlConnection
    output: string
    offset: int
    ignored: int
    pidfd: cint                  ## SO_PEERPIDFD, owned by the link until it closes
    closing: bool
    closingSince: int64          ## transport clock when the reply was complete
    closed: bool
  ControlTransport* = ref object
    listenFd*: cint
    server*: ControlServer
    accepting*: bool
    links: Table[cint, Link]
    clock: TransportClock
    peerFor: PeerLookup
    acceptPausedUntil: int64

proc setNonBlocking(fd: cint) =
  let flags = fcntl(fd, F_GETFL)
  if flags >= 0: discard fcntl(fd, F_SETFL, flags or O_NONBLOCK)
  discard fcntl(fd, F_SETFD, FD_CLOEXEC)

proc newControlTransport*(listenFd: cint; server: ControlServer;
                          clock: TransportClock; peerFor: PeerLookup): ControlTransport =
  if server.isNil or clock.isNil or peerFor.isNil:
    raise newException(ValueError, "transport requires a server, a clock and a peer lookup")
  if listenFd >= 0: setNonBlocking(listenFd)
  ControlTransport(listenFd: listenFd, server: server, accepting: listenFd >= 0,
    links: initTable[cint, Link](), clock: clock, peerFor: peerFor)

proc connectionCount*(transport: ControlTransport): int = transport.links.len

proc closeLink(transport: ControlTransport; link: Link) =
  if link.closed: return
  link.closed = true
  discard posix.close(link.fd)
  # The peer's pidfd lives exactly as long as the connection: rejected,
  # idle-expired, malformed, EOF and completed connections all end here.
  if link.pidfd >= 0:
    discard posix.close(link.pidfd)
    link.pidfd = -1
  transport.links.del(link.fd)

proc flush(transport: ControlTransport; link: Link) =
  while not link.closed and link.offset < link.output.len:
    let n = posix.send(SocketHandle(link.fd), unsafeAddr link.output[link.offset],
      link.output.len - link.offset, SendFlags)
    if n > 0:
      link.offset += n
    elif n < 0 and (errno == EINTR): continue
    elif n < 0 and (errno == EAGAIN or errno == EWOULDBLOCK): break
    else:
      # The peer is gone: the connection is closed and its request cancelled.
      link.output.setLen(0); link.offset = 0
      if not link.connection.isNil: link.connection.disconnect()
      transport.closeLink(link)
      return
  if link.offset >= link.output.len:
    link.output.setLen(0); link.offset = 0
    if link.closing: transport.closeLink(link)
  elif link.offset > ReadChunk:
    link.output = link.output[link.offset .. ^1]
    link.offset = 0

proc register(transport: ControlTransport; raw: cint) =
  ## One accepted connection. A separate proc, so each connection's closures
  ## capture their own `link` (closures created in a loop body share one
  ## environment in Nim).
  setNonBlocking(raw)
  var peer: PeerCredentials
  try:
    peer = transport.peerFor(raw)
  except CatchableError:
    # Credentials are mandatory (§7.4 rules 5-6); without them, reject.
    peer = PeerCredentials(uid: -1, gid: -1, pid: -1, pidfd: -1)
  let link = Link(fd: raw, pidfd: if peer.pidfd >= 0: cint(peer.pidfd) else: -1)
  transport.links[raw] = link
  let rt = transport
  let write: WriteHandler = proc(data: string) =
    if link.closed: raise newException(IOError, "connection closed")
    if link.output.len - link.offset + data.len > MaxBufferedOutput:
      raise newException(IOError, "client is not reading its replies")
    link.output.add data
    rt.flush(link)
  let close: CloseHandler = proc() =
    if not link.closing: link.closingSince = rt.clock()
    link.closing = true
    rt.flush(link)
  link.connection = openControlConnection(transport.server, peer,
    transport.clock(), write, close)

proc accept(transport: ControlTransport) =
  while transport.accepting:
    var address: Sockaddr_un
    var length = SockLen(sizeof(address))
    let fd = posix.accept(SocketHandle(transport.listenFd),
      cast[ptr SockAddr](addr address), addr length)
    if fd == SocketHandle(-1):
      if errno == EINTR: continue
      if errno == EMFILE or errno == ENFILE or errno == ENOBUFS or errno == ENOMEM:
        transport.acceptPausedUntil = transport.clock() + AcceptPauseMs
      break                       # EAGAIN, or a transient accept failure
    transport.register(cint(fd))

proc readLink(transport: ControlTransport; link: Link) =
  var buffer = newString(ReadChunk)
  var reads = 0
  while not link.closed:
    if reads >= MaxReadsPerTurn: return     # level-triggered: the next turn continues
    inc reads
    let n = posix.recv(SocketHandle(link.fd), addr buffer[0], ReadChunk, 0)
    if n > 0:
      if link.connection.requestDispatched or link.connection.closed:
        # Extra bytes after the request are ignored, within a limit.
        link.ignored += n
        if link.ignored > MaxIgnoredAfterRequest:
          if not link.connection.closed: link.connection.disconnect()
          transport.closeLink(link)
          return
        continue
      link.connection.feed(buffer[0 ..< n], transport.clock())
    elif n == 0:
      # EOF: before a response this cancels the request (§14.5).
      if not link.connection.closed: link.connection.disconnect()
      transport.closeLink(link)
      return
    elif errno == EINTR: continue
    elif errno == EAGAIN or errno == EWOULDBLOCK: return
    else:
      if not link.connection.closed: link.connection.disconnect()
      transport.closeLink(link)
      return

proc pollSet*(transport: ControlTransport; fds: var seq[TPollfd]) =
  ## Append the descriptors to poll.
  if transport.accepting and transport.listenFd >= 0 and
      transport.clock() >= transport.acceptPausedUntil:
    fds.add TPollfd(fd: transport.listenFd, events: POLLIN)
  for fd, link in transport.links:
    var events: cshort = 0
    if not link.closing: events = events or POLLIN
    if link.offset < link.output.len: events = events or POLLOUT
    fds.add TPollfd(fd: fd, events: events)

proc owns*(transport: ControlTransport; fd: cint): bool =
  fd == transport.listenFd or transport.links.hasKey(fd)

proc handle*(transport: ControlTransport; fd: cint; revents: cshort) =
  ## Act on one descriptor `poll` reported. Tolerates descriptors that were
  ## closed meanwhile (handlers may run nested event-loop turns).
  if fd == transport.listenFd:
    if (revents and POLLIN) != 0: transport.accept()
    return
  if not transport.links.hasKey(fd): return
  let link = transport.links[fd]
  if (revents and POLLOUT) != 0: transport.flush(link)
  if link.closed: return
  if (revents and (POLLIN or POLLHUP or POLLERR)) != 0:
    if link.closing:
      # The response is written; drop whatever the client still sends.
      if (revents and (POLLHUP or POLLERR)) != 0: transport.closeLink(link)
    else:
      transport.readLink(link)

proc expire*(transport: ControlTransport; nowMs: int64) =
  ## §14.5: close connections without a complete request within 10 seconds,
  ## and connections whose finished reply is still not read after
  ## `ClosingExpireMs`.
  var links: seq[Link]
  for link in transport.links.values: links.add link
  for link in links:
    if link.closed: continue
    if link.closing:
      if nowMs - link.closingSince >= ClosingExpireMs:
        link.output.setLen(0); link.offset = 0
        transport.closeLink(link)
    elif not link.connection.isNil:
      discard link.connection.expireIdle(nowMs)

proc abort*(transport: ControlTransport; fd: cint) =
  ## Drop one connection whose handling failed (its request is cancelled).
  if not transport.links.hasKey(fd): return
  let link = transport.links[fd]
  try:
    if not link.connection.isNil and not link.connection.closed:
      link.connection.disconnect()
  finally:
    transport.closeLink(link)

proc stopAccepting*(transport: ControlTransport) =
  transport.accepting = false

proc close*(transport: ControlTransport) =
  ## Close the listener and every connection (requests are cancelled).
  transport.accepting = false
  if transport.listenFd >= 0:
    discard posix.close(transport.listenFd)
    transport.listenFd = -1
  var links: seq[Link]
  for link in transport.links.values: links.add link
  for link in links:
    if not link.connection.isNil and not link.connection.closed:
      link.connection.disconnect()
    transport.closeLink(link)
