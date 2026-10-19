## Strict transport-independent control socket codec (§14.5).
import std/[json, options, sets, strutils, tables]
import jumpstartcore/errors
export errors

const MaxControlLineBytes* = 1024 * 1024

type
  ProtocolError* = CoreError ## All parser/serializer failures are E_PROTOCOL.
  ClientInfo* = object
    name*, version*: string
  RequestKind* = enum rkService, rkOp, rkCore, rkSession, rkPower, rkUsers, rkEnv
  ServiceRequest* = object
    name*, action*: string
    now*: Option[string] # Legacy protocol field is a string, not a boolean.
    args*: JsonNode
  OpRequest* = object
    core*, name*: string
    args*: JsonNode
  CoreRequest* = object
    name*: Option[string]
    action*: string
    stopUnits*: Option[bool]
  SessionRequest* = object
    action*: string
    uid*: int64
    id*: string
  PowerRequest* = object
    action*: string
  UsersRequest* = object
    action*: string
  EnvRequest* = object
    action*: string
    vars*: JsonNode
  ControlRequest* = object
    client*: ClientInfo
    case kind*: RequestKind
    of rkService: service*: ServiceRequest
    of rkOp: op*: OpRequest
    of rkCore: core*: CoreRequest
    of rkSession: session*: SessionRequest
    of rkPower: power*: PowerRequest
    of rkUsers: users*: UsersRequest
    of rkEnv: env*: EnvRequest
  ResponseStatus* = enum rsOk, rsError
  ErrorInfo* = object
    code*: CoreErrorCode
    message*: string
  ControlResponse* = object
    core*: string                ## core that handled the request, "" if none
    case status*: ResponseStatus
    of rsOk:
      result*: JsonNode
      warnings*: seq[string]
    of rsError: error*: ErrorInfo

proc protocol(message: string) {.noreturn.} =
  raise newCoreError(ecProtocol, message)

proc asObject(n: JsonNode, where: string): JsonNode =
  if n.isNil or n.kind != JObject: protocol(where & " must be an object")
  n

proc rejectUnknown(n: JsonNode, allowed: openArray[string], where: string) =
  var names = initHashSet[string]()
  for key in allowed: names.incl key
  for key, _ in n:
    if key notin names: protocol("unknown field " & where & "." & key)

proc required(n: JsonNode, key, where: string): JsonNode =
  if not n.hasKey(key): protocol("missing field " & where & "." & key)
  n[key]

proc stringField(n: JsonNode, key, where: string): string =
  let value = required(n, key, where)
  if value.kind != JString: protocol(where & "." & key & " must be a string")
  value.getStr

proc optString(n: JsonNode, key, where: string): Option[string] =
  if not n.hasKey(key): return none(string)
  if n[key].kind != JString: protocol(where & "." & key & " must be a string")
  some(n[key].getStr)

proc optBool(n: JsonNode, key, where: string): Option[bool] =
  if not n.hasKey(key): return none(bool)
  if n[key].kind != JBool: protocol(where & "." & key & " must be a boolean")
  some(n[key].getBool)

proc objectField(n: JsonNode, key, where: string): JsonNode =
  if not n.hasKey(key): return newJObject()
  asObject(n[key], where & "." & key)

proc stringMapField(n: JsonNode, key, where: string): JsonNode =
  result = objectField(n, key, where)
  for name, value in result:
    if value.kind != JString:
      protocol(where & "." & key & "." & name & " must be a string")

proc envMapField(n: JsonNode, key, where: string): JsonNode =
  ## `env` variables: a string value sets, `null` names a key without a value
  ## (`unset` and `import`, §21.9).
  result = objectField(n, key, where)
  for name, value in result:
    if value.kind notin {JString, JNull}:
      protocol(where & "." & key & "." & name & " must be a string or null")

proc stringList(n: JsonNode, key, where: string): seq[string] =
  if not n.hasKey(key): return @[]
  if n[key].kind != JArray: protocol(where & "." & key & " must be an array")
  for value in n[key]:
    if value.kind != JString: protocol(where & "." & key & " values must be strings")
    result.add value.getStr

proc parseNode(line: string): JsonNode =
  var payload = line
  if payload.endsWith("\n"): payload.setLen(payload.len - 1)
  if payload.endsWith("\r"): payload.setLen(payload.len - 1)
  if payload.len > MaxControlLineBytes: protocol("control line exceeds 1 MiB")
  if '\n' in payload or '\r' in payload: protocol("expected exactly one complete line")
  if payload.len == 0: protocol("empty control line")
  try: result = parseJson(payload)
  except JsonParsingError as exc: protocol("malformed JSON: " & exc.msg)
  discard asObject(result, "message")

proc parseClient(n: JsonNode): ClientInfo =
  discard asObject(n, "client")
  rejectUnknown(n, ["name", "version"], "client")
  ClientInfo(name: stringField(n, "name", "client"),
             version: stringField(n, "version", "client"))

proc parseControlRequest*(line: string): ControlRequest =
  let root = parseNode(line)
  const variants = ["service", "op", "core", "session", "power", "users", "env"]
  rejectUnknown(root, ["client", "service", "op", "core", "session", "power", "users", "env"], "request")
  let client = parseClient(required(root, "client", "request"))
  var selected = ""
  for key in variants:
    if root.hasKey(key):
      if selected.len != 0: protocol("request must contain exactly one request variant")
      selected = key
  if selected.len == 0: protocol("request must contain exactly one request variant")
  let body = asObject(root[selected], selected)
  case selected
  of "service":
    rejectUnknown(body, ["name", "action", "now", "args"], "service")
    result = ControlRequest(kind: rkService, client: client,
      service: ServiceRequest(name: stringField(body, "name", "service"),
        action: stringField(body, "action", "service"),
        now: optString(body, "now", "service"), args: objectField(body, "args", "service")))
  of "op":
    rejectUnknown(body, ["core", "name", "args"], "op")
    result = ControlRequest(kind: rkOp, client: client,
      op: OpRequest(core: stringField(body, "core", "op"), name: stringField(body, "name", "op"),
        args: objectField(body, "args", "op")))
  of "core":
    rejectUnknown(body, ["name", "action", "stop_units"], "core")
    result = ControlRequest(kind: rkCore, client: client,
      core: CoreRequest(name: optString(body, "name", "core"), action: stringField(body, "action", "core"),
        stopUnits: optBool(body, "stop_units", "core")))
  of "session":
    rejectUnknown(body, ["action", "uid", "id"], "session")
    let uid = required(body, "uid", "session")
    if uid.kind != JInt or uid.getBiggestInt < 0: protocol("session.uid must be a non-negative integer")
    result = ControlRequest(kind: rkSession, client: client,
      session: SessionRequest(action: stringField(body, "action", "session"), uid: uid.getBiggestInt,
        id: stringField(body, "id", "session")))
  of "power":
    rejectUnknown(body, ["action"], "power")
    result = ControlRequest(kind: rkPower, client: client,
      power: PowerRequest(action: stringField(body, "action", "power")))
  of "users":
    rejectUnknown(body, ["action"], "users")
    result = ControlRequest(kind: rkUsers, client: client,
      users: UsersRequest(action: stringField(body, "action", "users")))
  of "env":
    rejectUnknown(body, ["action", "vars"], "env")
    result = ControlRequest(kind: rkEnv, client: client,
      env: EnvRequest(action: stringField(body, "action", "env"), vars: envMapField(body, "vars", "env")))
  else: doAssert false

proc toJson*(request: ControlRequest): JsonNode =
  result = newJObject()
  result["client"] = %* {"name": request.client.name, "version": request.client.version}
  case request.kind
  of rkService:
    var n = %* {"name": request.service.name, "action": request.service.action}
    if request.service.now.isSome: n["now"] = %request.service.now.get
    if not request.service.args.isNil: n["args"] = asObject(request.service.args, "service.args")
    result["service"] = n
  of rkOp:
    var n = %* {"core": request.op.core, "name": request.op.name}
    if not request.op.args.isNil: n["args"] = asObject(request.op.args, "op.args")
    result["op"] = n
  of rkCore:
    var n = %* {"action": request.core.action}
    if request.core.name.isSome: n["name"] = %request.core.name.get
    if request.core.stopUnits.isSome: n["stop_units"] = %request.core.stopUnits.get
    result["core"] = n
  of rkSession: result["session"] = %* {"action": request.session.action, "uid": request.session.uid, "id": request.session.id}
  of rkPower: result["power"] = %* {"action": request.power.action}
  of rkUsers: result["users"] = %* {"action": request.users.action}
  of rkEnv:
    var n = %* {"action": request.env.action}
    if not request.env.vars.isNil: n["vars"] = asObject(request.env.vars, "env.vars")
    result["env"] = n

proc parseControlResponse*(line: string): ControlResponse =
  let root = parseNode(line)
  if stringField(root, "type", "response") != "response": protocol("unknown response type")
  case stringField(root, "status", "response")
  of "ok":
    rejectUnknown(root, ["type", "status", "result", "warnings", "core"], "response")
    result = ControlResponse(status: rsOk, result: objectField(root, "result", "response"),
      warnings: stringList(root, "warnings", "response"))
    result.core = optString(root, "core", "response").get("")
  of "error":
    rejectUnknown(root, ["type", "status", "error"], "response")
    let e = asObject(required(root, "error", "response"), "response.error")
    rejectUnknown(e, ["code", "message", "core"], "response.error")
    let codeName = stringField(e, "code", "response.error")
    var code: CoreErrorCode
    try: code = parseErrorCode(codeName)
    except ValueError: protocol("unknown response error code: " & codeName)
    result = ControlResponse(status: rsError,
      error: ErrorInfo(code: code, message: stringField(e, "message", "response.error")))
    result.core = optString(e, "core", "response.error").get("")
  else: protocol("unknown response status")

proc okResponse*(value: JsonNode = nil; warnings: seq[string] = @[]): ControlResponse =
  ControlResponse(status: rsOk,
    result: if value.isNil: newJObject() else: asObject(value, "response.result"),
    warnings: warnings)

proc uncodedErrorCode*(e: ref Exception): CoreErrorCode =
  ## §18: an exception that carries no code is `E_IO` when it is a filesystem
  ## or socket error (`OSError`, `IOError`), otherwise `E_BACKEND`.
  if e of OSError or e of IOError: ecIo else: ecBackend

proc errorResponse*(code: CoreErrorCode; message: string; core = ""): ControlResponse =
  ControlResponse(status: rsError, core: core,
    error: ErrorInfo(code: code, message: message))

proc toJson*(response: ControlResponse): JsonNode =
  case response.status
  of rsOk:
    result = %* {"type": "response", "status": "ok"}
    result["result"] = if response.result.isNil: newJObject() else: asObject(response.result, "response.result")
    result["warnings"] = %response.warnings
    if response.core.len > 0: result["core"] = %response.core
  of rsError:
    result = %* {"type": "response", "status": "error",
      "error": {"code": errorName(response.error.code), "message": response.error.message}}
    if response.core.len > 0: result["error"]["core"] = %response.core

proc encodeLine(node: JsonNode): string =
  result = $node
  if result.len > MaxControlLineBytes: protocol("control line exceeds 1 MiB")
  result.add '\n'

proc serializeControlRequest*(request: ControlRequest): string = encodeLine(toJson(request))
proc serializeControlResponse*(response: ControlResponse): string = encodeLine(toJson(response))
proc parseRequest*(line: string): ControlRequest = parseControlRequest(line)
proc parseResponse*(line: string): ControlResponse = parseControlResponse(line)
proc serialize*(request: ControlRequest): string = serializeControlRequest(request)
proc serialize*(response: ControlResponse): string = serializeControlResponse(response)


# ---------------------------------------------------------------------------
# Events (§14.5, §17.4)
#
# Streaming operations send `event` lines before the response, and list fields
# of a result may be delivered as `item` events to stay within the line limit.
# A connection carries one request, so control-socket events carry no id:
#
#   {"type":"event","event":"entry","data":{...}}
#   {"type":"event","event":"item","field":"units","data":{...}}

type
  ControlEventKind* = enum cekEntry, cekItem
  ControlEvent* = object
    kind*: ControlEventKind
    field*: string               ## cekItem: the result list field
    data*: JsonNode
  ControlMessageKind* = enum cmkEvent, cmkResponse
  ControlMessage* = object
    case kind*: ControlMessageKind
    of cmkEvent: event*: ControlEvent
    of cmkResponse: response*: ControlResponse

proc entryControlEvent*(data: JsonNode): ControlEvent =
  ControlEvent(kind: cekEntry, data: data)

proc itemControlEvent*(field: string; data: JsonNode): ControlEvent =
  ControlEvent(kind: cekItem, field: field, data: data)

proc toJson*(event: ControlEvent): JsonNode =
  result = %* {"type": "event"}
  case event.kind
  of cekEntry:
    result["event"] = %"entry"
  of cekItem:
    result["event"] = %"item"
    result["field"] = %event.field
  result["data"] = if event.data.isNil: newJNull() else: event.data

proc serializeControlEvent*(event: ControlEvent): string = encodeLine(toJson(event))
proc serialize*(event: ControlEvent): string = serializeControlEvent(event)

proc parseControlEvent(root: JsonNode): ControlEvent =
  case stringField(root, "event", "event")
  of "entry":
    rejectUnknown(root, ["type", "event", "data"], "event")
    result = ControlEvent(kind: cekEntry, data: asObject(required(root, "data", "event"), "event.data"))
  of "item":
    rejectUnknown(root, ["type", "event", "field", "data"], "event")
    let field = stringField(root, "field", "event")
    if field.len == 0: protocol("event.field must not be empty")
    result = ControlEvent(kind: cekItem, field: field, data: required(root, "data", "event"))
  else: protocol("unknown event kind")

proc parseControlLine*(line: string): ControlMessage =
  ## Parse one line a client receives: an `event` or the final `response`.
  let root = parseNode(line)
  case stringField(root, "type", "message")
  of "event": ControlMessage(kind: cmkEvent, event: parseControlEvent(root))
  of "response": ControlMessage(kind: cmkResponse, response: parseControlResponse(line))
  else: protocol("unknown message type")

proc mergeItems*(response: ControlResponse; items: openArray[ControlEvent]): ControlResponse =
  ## Merge buffered `item` events into an ok response (§17.4).
  result = response
  if response.status != rsOk or items.len == 0: return
  var merged = if response.result.isNil: newJObject() else: response.result.copy
  var byField = initOrderedTable[string, seq[JsonNode]]()
  for item in items:
    if item.kind == cekItem: byField.mgetOrPut(item.field, @[]).add item.data
  for field, values in byField:
    var combined = newJArray()
    for v in values: combined.add v
    if merged.hasKey(field) and merged[field].kind == JArray:
      for v in merged[field]: combined.add v
    merged[field] = combined
  result.result = merged

proc splitOversize*(response: ControlResponse;
                    limit = MaxControlLineBytes): tuple[items: seq[ControlEvent]; response: ControlResponse] =
  ## Daemon side of §14.5: when an ok response would exceed the line limit,
  ## move the elements of its list fields into `item` events. Fails with
  ## `E_PROTOCOL` when even the remainder does not fit.
  result.response = response
  if response.status != rsOk: return
  if ($toJson(response)).len + 1 <= limit: return
  var rest = response.result.copy
  for key, value in response.result:
    if value.kind == JArray:
      for element in value:
        let event = itemControlEvent(key, element)
        if ($toJson(event)).len + 1 > limit:
          protocol("list element of " & key & " exceeds 1 MiB")
        result.items.add event
      rest[key] = newJArray()
  result.response.result = rest
  if ($toJson(result.response)).len + 1 > limit: protocol("control response exceeds 1 MiB")
