import std/[json, options, strutils, unittest]
import ../../jumpstart/cores/daemon/control

const Client = "\"client\":{\"name\":\"test\",\"version\":\"1.0\"}"

suite "Jumpstart core control protocol":
  test "parses all request variants into typed values":
    let service = parseRequest("{" & Client & ",\"service\":{\"name\":\"systemd/sshd.service\",\"action\":\"restart\",\"now\":\"false\",\"args\":{}}}\n")
    check service.kind == rkService
    check service.service.name == "systemd/sshd.service"
    check service.service.now.get == "false"

    check parseRequest("{" & Client & ",\"op\":{\"core\":\"systemd\",\"name\":\"log.rotate\",\"args\":{}}}").kind == rkOp
    let core = parseRequest("{" & Client & ",\"core\":{\"name\":\"systemd\",\"action\":\"reload\",\"stop_units\":false}}")
    check core.kind == rkCore
    check core.core.stopUnits.get == false
    check parseRequest("{" & Client & ",\"session\":{\"action\":\"open\",\"uid\":1000,\"id\":\"c2\"}}").kind == rkSession
    check parseRequest("{" & Client & ",\"power\":{\"action\":\"poweroff\"}}").kind == rkPower
    check parseRequest("{" & Client & ",\"users\":{\"action\":\"list\"}}").kind == rkUsers
    let env = parseRequest("{" & Client & ",\"env\":{\"action\":\"set\",\"vars\":{\"DISPLAY\":\":0\"}}}")
    check env.kind == rkEnv
    check env.env.vars["DISPLAY"].getStr == ":0"

  test "legacy service args may be omitted":
    let request = parseRequest("{" & Client & ",\"service\":{\"name\":\"sshd\",\"action\":\"start\"}}")
    check request.service.args.kind == JObject
    check request.service.args.len == 0

  test "rejects malformed, unknown, ambiguous, and wrongly typed requests":
    expect ProtocolError: discard parseRequest("not json")
    expect ProtocolError: discard parseRequest("[]")
    expect ProtocolError: discard parseRequest("{" & Client & ",\"bogus\":{}}")
    expect ProtocolError: discard parseRequest("{" & Client & ",\"power\":{\"action\":\"halt\",\"extra\":1}}")
    expect ProtocolError: discard parseRequest("{" & Client & ",\"power\":{\"action\":true}}")
    expect ProtocolError: discard parseRequest("{" & Client & ",\"power\":{\"action\":\"halt\"},\"users\":{\"action\":\"list\"}}")
    expect ProtocolError: discard parseRequest("{\"client\":{\"name\":\"x\",\"version\":3},\"users\":{\"action\":\"list\"}}")
    expect ProtocolError: discard parseRequest("{" & Client & ",\"env\":{\"action\":\"set\",\"vars\":{\"DISPLAY\":2}}}")

  test "enforces the one MiB line limit in both directions":
    let oversized = "{" & Client & ",\"power\":{\"action\":\"" & repeat('x', MaxControlLineBytes) & "\"}}"
    expect ProtocolError: discard parseRequest(oversized)
    let huge = ControlResponse(status: rsOk, result: %* {"value": repeat('x', MaxControlLineBytes)}, warnings: @[])
    expect ProtocolError: discard serialize(huge)

  test "parses and serializes typed responses":
    let ok = parseResponse("{\"type\":\"response\",\"status\":\"ok\",\"result\":{\"state\":\"active\"},\"warnings\":[\"late\"]}\n")
    check ok.status == rsOk
    check ok.result["state"].getStr == "active"
    check ok.warnings == @["late"]
    check parseResponse(serialize(ok)).status == rsOk

    let failure = parseResponse("{\"type\":\"response\",\"status\":\"error\",\"error\":{\"code\":\"E_UNSUPPORTED\",\"message\":\"no\"}}")
    check failure.status == rsError
    check failure.error.code == ecUnsupported
    check parseResponse(serialize(failure)).error.message == "no"

  test "response schema is strict":
    expect ProtocolError: discard parseResponse("{\"type\":\"event\",\"status\":\"ok\"}")
    expect ProtocolError: discard parseResponse("{\"type\":\"response\",\"status\":\"maybe\"}")
    expect ProtocolError: discard parseResponse("{\"type\":\"response\",\"status\":\"error\",\"error\":{\"code\":1,\"message\":\"x\"}}")
    expect ProtocolError: discard parseResponse("{\"type\":\"response\",\"status\":\"error\",\"error\":{\"code\":\"E_UNKNOWN\",\"message\":\"x\"}}")
    expect ProtocolError: discard parseResponse("{\"type\":\"response\",\"status\":\"ok\",\"result\":{},\"other\":1}")

  test "request serialization emits one NDJSON line and round trips":
    let original = parseRequest("{" & Client & ",\"env\":{\"action\":\"set\",\"vars\":{\"DISPLAY\":\":1\"}}}")
    let line = serialize(original)
    check line[^1] == '\n'
    check line[0 ..< line.high].find('\n') < 0
    let decoded = parseRequest(line)
    check decoded.kind == rkEnv
    check decoded.env.vars["DISPLAY"].getStr == ":1"
