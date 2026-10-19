import std/[json, strutils, times, unittest]
import jumpstartcore/[errors, protocol]

suite "core exec protocol":
  test "all message forms round trip as newline JSON":
    let messages = @[
      helloOffer(crAdapter, "systemd", "system", "1.3.0"),
      helloReply(crAdapter, @["service.start", "service.stop"]),
      request("7", "service.start", "sshd.service", newJObject(), "2026-10-16T12:00:30Z"),
      request("8", "unit.resolve", "sshd", %*{"name": "sshd"}, "2026-10-16T12:00:30Z", "resolve"),
      okResponse("7", %*{"state": "active"}),
      errorResponse("7", "E_BACKEND", "failed"), cancel("7"),
      entryEvent("7", %*{"message": "hello"}), itemEvent("7", "units", %*{"name": "sshd"}),
      notification("sshd.service", "failed", "status 1"), filesystemsReady()]
    for message in messages:
      let line = encodeLine(message)
      check line.endsWith("\n")
      check encodeLine(parseLine(line)) == line

  test "strict schemas reject unknown missing and ill-typed fields":
    for line in [
      "{}", "[]", "{", "{\"type\":\"wat\"}",
      "{\"type\":\"cancel\"}",
      "{\"type\":\"cancel\",\"id\":7}",
      "{\"type\":\"cancel\",\"id\":\"7\",\"extra\":true}",
      "{\"type\":\"response\",\"id\":\"7\",\"status\":\"ok\",\"result\":[]}",
      "{\"type\":\"event\",\"id\":\"7\",\"event\":\"entry\",\"data\":[]}",
      "{\"type\":\"notify\",\"unit\":\"x\",\"state\":\"dead\"}"]:
      expect ProtocolError: discard parseLine(line)

  test "line and UTF-8 limits are exact":
    let base = "{\"type\":\"filesystems-ready\"}"
    check parseLine(base & " ".repeat(MaxProtocolLineBytes - base.len)).kind == pmFilesystemsReady
    expect ProtocolError: discard parseLine(" " .repeat(MaxProtocolLineBytes + 1))
    expect ProtocolError: discard parseLine("{\"type\":\"cancel\",\"id\":\"x\"}\\n{}")
    expect ProtocolError: discard parseLine("\xFF")
    let huge = okResponse("x", %*{"value": "x".repeat(MaxProtocolLineBytes)})
    expect ProtocolError: discard encodeLine(huge)

  test "handshake validates roles selected protocol and adapter operation set":
    let offer = helloOffer(crAdapter, "systemd", "system", "1.3")
    validateHandshake(offer, helloReply(crAdapter, @["service.stop", "service.start"]),
      ["service.start", "service.stop"])
    expect ProtocolError:
      validateHandshake(offer, helloReply(crRunner), ["service.start"])
    expect ProtocolError:
      validateHandshake(offer, helloReply(crAdapter, @["service.start"]),
        ["service.start", "service.stop"])
    expect ProtocolError:
      validateHandshake(offer, helloReply(crAdapter, @["service.start"], "other/1"),
        ["service.start"])

  test "typed failures always report E_PROTOCOL":
    try:
      discard parseLine("nope")
      check false
    except ProtocolError as error:
      check error.code == ecProtocol

  test "notification details and unknown state are constrained":
    expect ProtocolError: discard notification("x", "unknown")
    discard notification("x", "unknown", "backend unavailable")
    expect ProtocolError: discard notification("x", "failed", "x".repeat(513))

  test "requests may omit the unit for non-unit-addressed operations":
    # §17.3: `core.*` verification and global operations carry no unit.
    let empty = request("id1", "core.verify", "", newJObject(),
      "2026-10-16T12:00:30Z")
    check empty.unit.len == 0
    check parseLine(encodeLine(empty)).unit.len == 0
    expect ProtocolError:
      discard request("id2", "service.start", "bad/unit", newJObject(),
        "2026-10-16T12:00:30Z")

suite "RFC 3339 deadlines (§16.2, §17.3)":
  test "formatter produces UTC RFC 3339 and round-trips":
    let t = fromUnix(1792152030)
    check formatDeadline(t) == "2026-10-16T12:00:30Z"
    check parseDeadline(formatDeadline(t)) == t
    check formatDeadline(fromUnixFloat(1792152030.999)) == "2026-10-16T12:00:30Z"
    let later = deadlineAfter(30_000, t)
    check later == "2026-10-16T12:01:00Z"

  test "parser accepts offsets and fractions, rejects everything else":
    check parseDeadline("2026-10-16T14:00:30+02:00") == fromUnix(1792152030)
    check parseDeadline("2026-10-16T12:00:30.250Z").toUnixFloat == 1792152030.25
    for bad in ["x", "2026-10-16 12:00:30Z", "2026-10-16T12:00:30", "2026-13-01T00:00:00Z",
                "2026-02-30T00:00:00Z", "2026-10-16T12:00:30+0200", "1792152030"]:
      check not validDeadline(bad)

  test "requests require an RFC 3339 deadline":
    expect ProtocolError:
      discard request("r", "service.start", "web", newJObject(), "in 30 seconds")
    expect ProtocolError:
      discard parseLine("""{"type":"request","id":"r","op":"service.start","unit":"web","args":{},"deadline":"x"}""")

suite "result schema validation (§16.3)":
  test "registry fields, types and closed vocabularies":
    validateResult("service.start", %*{"state": "active"})
    validateResult("service.status", %*{"state": "failed", "detail": "x",
      "enablement": "static", "pids": [1, 2], "exit_code": 3})
    validateResult("unit.list", %*{"units": [{"name": "a", "subsystem": "service",
      "enablement": "enabled"}]})
    validateResult("service.enable", newJObject())
    for (op, value) in [
        ("service.start", %*{}),
        ("service.start", %*{"state": "active", "detail": ""}),
        ("service.start", %*{"state": "running"}),
        ("service.status", %*{"state": "active", "detail": "", "enablement": "on"}),
        ("service.status", %*{"state": "active", "detail": "", "enablement": "enabled", "main_pid": "7"}),
        ("core.verify", %*{"installed": "true", "version": "1"}),
        ("unit.list", %*{"units": [{"name": "a", "subsystem": "service"}]}),
        ("unit.list", %*{"units": [{"name": "a", "subsystem": "service", "enablement": "enabled", "state": "active"}]}),
        ("service.enable", %*{"state": "active"})]:
      check not resultIsValid(op, value)
    check not resultIsValid("service.status", %*{"state": "active",
      "detail": "x".repeat(513), "enablement": "enabled"})

  test "reloading and the optional status fields (§12.11)":
    check "reloading" in UnitStates
    validateResult("service.start", %*{"state": "reloading"})
    discard notification("sshd.service", "reloading")
    validateResult("mount.status", %*{"state": "reloading", "detail": "", "enablement": "static",
      "source": "/dev/sda1", "target": "/", "fstype": "ext4",
      "since": "2026-10-17T12:00:00Z", "substate": "remounting", "result": "success"})
    validateResult("service.status", %*{"state": "active", "detail": "", "enablement": "enabled",
      "since": "2026-10-17T12:00:00.123456+02:00", "substate": "running",
      "result": "exit-code", "main_pid": 7})
    # Each is optional and independent.
    validateResult("target.status", %*{"state": "active", "detail": "", "enablement": "static",
      "members": [], "substate": "active"})
    for bad in [
        %*{"since": "yesterday"}, %*{"since": "2026-10-17"}, %*{"since": 5},
        %*{"substate": ""}, %*{"substate": "Running"}, %*{"substate": "run ning"},
        %*{"substate": "a_b"}, %*{"substate": "x".repeat(65)}, %*{"substate": 3},
        %*{"result": ""}, %*{"result": "EXIT"}, %*{"result": "x".repeat(65)},
        %*{"extra": "x"}]:
      var value = %*{"state": "active", "detail": "", "enablement": "enabled"}
      for key, item in bad: value[key] = item
      check not resultIsValid("service.status", value)
    # Exactly 64 bytes, digits and hyphens are fine.
    validateResult("service.status", %*{"state": "active", "detail": "",
      "enablement": "enabled", "substate": "x".repeat(64), "result": "a-1-b"})
    check validStatusToken("auto-restart")
    check not validStatusToken("auto_restart")

  test "error responses keep defined codes":
    check responseFailure(errorResponse("r", "E_UNIT_STATE", "inactive"))[0] == ecUnitState
    check responseFailure(errorResponse("r", "E_NOPE", "?"))[0] == ecProtocol
