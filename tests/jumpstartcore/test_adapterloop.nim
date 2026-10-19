import std/[json, os, posix, strutils, times, unittest]
import jumpstartcore/[adapterloop, errors, jsonlines, protocol]

const Deadline = "2099-01-01T00:00:00Z"

type Wire = object
  inRead, inWrite, outRead, outWrite: cint

proc newWire(): Wire =
  var a, b: array[2, cint]
  doAssert pipe(a) == 0 and pipe(b) == 0
  Wire(inRead: a[0], inWrite: a[1], outRead: b[0], outWrite: b[1])

proc parseRole(role: string): CoreRole =
  case role
  of "supervisor": crSupervisor
  of "runner": crRunner
  else: crAdapter

proc offerLine(role = "adapter"): string =
  encodeLine(helloOffer(parseRole(role), "demo", "system", "2.0.0"))

proc req(id, op: string; unit = ""; deadline = Deadline): string =
  encodeLine(request(id, op, unit, newJObject(), deadline))

proc runSession(session: AdapterSession; wire: Wire; input: string): tuple[status: int; output: seq[ProtocolMessage]] =
  ## Everything the peer sends is written first and descriptor 3 is closed, so
  ## `serve` sees EOF after the last message.
  writeAllFd(wire.inWrite, input)
  discard close(wire.inWrite)
  result.status = session.serve()
  discard close(wire.outWrite)
  let reader = newLineReader(wire.outRead)
  var line: string
  while reader.readLine(line): result.output.add parseLine(line)
  discard close(wire.outRead)

proc newSession(wire: Wire): AdapterSession =
  newAdapterSession(crAdapter, wire.inRead, wire.outWrite)

suite "adapterloop":
  test "hello reply declares exactly the registered operations":
    let wire = newWire()
    let session = newSession(wire)
    session.handle("service.start", proc(ctx: RequestContext): JsonNode = %*{"state": "active"})
    session.handle("service.status", proc(ctx: RequestContext): JsonNode =
      %*{"state": "active", "detail": "", "enablement": "enabled"})
    let (status, output) = runSession(session, wire, offerLine())
    check status == 0
    check output.len == 1
    check output[0].kind == pmHelloReply
    check output[0].role == crAdapter
    check output[0].protocol == CoreProtocol
    check output[0].operations == @["service.start", "service.status"]
    check session.offer.core == "demo"

  test "requests produce exactly one validated response each":
    let wire = newWire()
    let session = newSession(wire)
    session.handle("service.start", proc(ctx: RequestContext): JsonNode =
      check ctx.unit == "a.service"
      check ctx.remainingMs > 0
      %*{"state": "active"})
    let (status, output) = runSession(session, wire,
      offerLine() & req("1", "service.start", "a.service") & req("2", "service.start", "a.service"))
    check status == 0
    check output.len == 3
    check output[1].kind == pmResponseOk and output[1].id == "1"
    check output[2].kind == pmResponseOk and output[2].id == "2"
    check output[2].result["state"].getStr == "active"

  test "handler errors keep their code and other exceptions are E_BACKEND":
    let wire = newWire()
    let session = newSession(wire)
    session.handle("service.start", proc(ctx: RequestContext): JsonNode =
      raise newCoreError(ecNotFound, "no such unit"))
    session.handle("service.stop", proc(ctx: RequestContext): JsonNode =
      raise newException(ValueError, "boom"))
    let (_, output) = runSession(session, wire,
      offerLine() & req("1", "service.start", "a.service") & req("2", "service.stop", "a.service"))
    check output[1].kind == pmResponseError
    check output[1].error.code == "E_NOT_FOUND"
    check output[1].error.message == "no such unit"
    check output[2].error.code == "E_BACKEND"
    check output[2].error.message == "boom"

  test "an invalid result becomes E_PROTOCOL instead of reaching Jumpstart":
    let wire = newWire()
    let session = newSession(wire)
    session.handle("service.start", proc(ctx: RequestContext): JsonNode = %*{"state": "bogus"})
    let (_, output) = runSession(session, wire, offerLine() & req("1", "service.start", "a.service"))
    check output[1].kind == pmResponseError
    check output[1].error.code == "E_PROTOCOL"

  test "an operation that was not registered is E_UNSUPPORTED":
    let wire = newWire()
    let session = newSession(wire)
    session.handle("service.start", proc(ctx: RequestContext): JsonNode = %*{"state": "active"})
    let (_, output) = runSession(session, wire, offerLine() & req("1", "service.stop", "a.service"))
    check output[1].error.code == "E_UNSUPPORTED"

  test "item events precede the response and are validated":
    let wire = newWire()
    let session = newSession(wire)
    session.handle("unit.list", proc(ctx: RequestContext): JsonNode =
      ctx.emitItem("units", %*{"name": "a.service", "subsystem": "service", "enablement": "enabled"})
      ctx.emitItem("units", %*{"name": "b.service", "subsystem": "service", "enablement": "disabled"})
      %*{"units": []})
    let (_, output) = runSession(session, wire, offerLine() & req("1", "unit.list"))
    check output.len == 4
    check output[1].kind == pmEventItem and output[1].field == "units"
    check output[1].data["name"].getStr == "a.service"
    check output[2].kind == pmEventItem
    check output[3].kind == pmResponseOk

  test "emitItem rejects malformed items":
    let wire = newWire()
    let session = newSession(wire)
    session.handle("unit.list", proc(ctx: RequestContext): JsonNode =
      ctx.emitItem("units", %*{"name": "a.service"})
      %*{"units": []})
    let (_, output) = runSession(session, wire, offerLine() & req("1", "unit.list"))
    check output.len == 2
    check output[1].error.code == "E_PROTOCOL"

  test "a cancel message reaches the running handler":
    let wire = newWire()
    let session = newSession(wire)
    session.handle("service.start", proc(ctx: RequestContext): JsonNode =
      ctx.checkpoint()
      %*{"state": "active"})
    # All three messages are already in the pipe when the handler runs, so the
    # cancel is found by the handler's non-blocking look at descriptor 3.
    var observed = false
    session.handle("service.stop", proc(ctx: RequestContext): JsonNode =
      observed = ctx.cancelled
      ctx.checkpoint()
      %*{"state": "inactive"})
    let (_, output) = runSession(session, wire,
      offerLine() & req("1", "service.stop", "a.service") &
      encodeLine(cancel("1")) & req("2", "service.start", "a.service"))
    check observed
    check output[1].id == "1" and output[1].error.code == "E_CANCELLED"
    check output[2].id == "2" and output[2].kind == pmResponseOk

  test "a request cancelled while queued is answered without running":
    let wire = newWire()
    let session = newSession(wire)
    var ran: seq[string]
    session.handle("service.start", proc(ctx: RequestContext): JsonNode =
      ran.add ctx.id
      discard ctx.cancelled   # pulls the later messages into the queue
      %*{"state": "active"})
    let (_, output) = runSession(session, wire,
      offerLine() & req("1", "service.start", "a.service") &
      req("2", "service.start", "a.service") & encodeLine(cancel("2")))
    check ran == @["1"]
    check output[2].id == "2" and output[2].error.code == "E_CANCELLED"

  test "a deadline in the past fails with E_TIMEOUT before the handler runs":
    let wire = newWire()
    let session = newSession(wire)
    var ran = false
    session.handle("service.start", proc(ctx: RequestContext): JsonNode =
      ran = true
      %*{"state": "active"})
    let (_, output) = runSession(session, wire,
      offerLine() & req("1", "service.start", "a.service", "2001-01-01T00:00:00Z"))
    check not ran
    check output[1].error.code == "E_TIMEOUT"

  test "soft deadline lies before the deadline":
    let wire = newWire()
    let session = newSession(wire)
    session.handle("service.start", proc(ctx: RequestContext): JsonNode =
      check ctx.softDeadline < ctx.deadline
      check ctx.softDeadline(0) == ctx.deadline
      %*{"state": "active"})
    let (_, output) = runSession(session, wire, offerLine() & req("1", "service.start", "a.service"))
    check output[1].kind == pmResponseOk

  test "a malformed line ends the session with status 1":
    let wire = newWire()
    let session = newSession(wire)
    session.handle("service.start", proc(ctx: RequestContext): JsonNode = %*{"state": "active"})
    let (status, output) = runSession(session, wire, offerLine() & "not json\n")
    check status == 1
    check output.len == 1

  test "a hello offer for another role is refused without a reply":
    let wire = newWire()
    let session = newSession(wire)
    let (status, output) = runSession(session, wire, offerLine("runner"))
    check status == 1
    check output.len == 0

  test "EOF before hello is a failure":
    let wire = newWire()
    let session = newSession(wire)
    let (status, output) = runSession(session, wire, "")
    check status == 1
    check output.len == 0

  test "supervisor handshake carries no operations":
    let wire = newWire()
    let session = newAdapterSession(crSupervisor, wire.inRead, wire.outWrite)
    writeAllFd(wire.inWrite, offerLine("supervisor"))
    let offer = session.handshake()
    check offer.role == crSupervisor
    session.notify("a.service", "active", "ready")
    session.filesystemsReady()
    discard close(wire.outWrite)
    let reader = newLineReader(wire.outRead)
    var line: string
    var messages: seq[ProtocolMessage]
    while reader.readLine(line): messages.add parseLine(line)
    check messages.len == 3
    check messages[0].kind == pmHelloReply and messages[0].role == crSupervisor
    check messages[0].operations.len == 0
    check messages[1].kind == pmNotify and messages[1].state == "active"
    check messages[2].kind == pmFilesystemsReady
