## Transport-independent implementation of the Jumpstart core exec protocol.
##
## This module deliberately only deals in complete lines. Descriptor handling,
## timeouts, request-id bookkeeping, and notification rate limiting belong to
## the transport/session layer.
import std/[json, options, sets, strutils, times, unicode]
import ./[errors, names, registry, registry_types]

const
  CoreProtocol* = "jumpstart-core/1"
  MaxProtocolLineBytes* = 1024 * 1024
  UnitStates* = ["active", "inactive", "activating", "deactivating", "reloading",
                 "failed", "unknown"]
    ## §12.11
  MaxStatusTokenBytes* = 64
    ## §12.11: `substate` and `result` are at most 64 bytes.
  EnablementStates* = ["enabled", "disabled", "static", "indirect", "masked", "generated"]
    ## §12.12
  LogLevels* = ["debug", "info", "notice", "warn", "error", "fatal"]
    ## §12.10
  MaxDetailBytes* = 512
    ## §12.11: `detail` is at most 512 bytes.

type
  ProtocolError* = object of CoreError
    ## A typed CoreError whose code is always ecProtocol.

  CoreRole* = enum
    crAdapter, crSupervisor, crRunner

  MessageKind* = enum
    pmHelloOffer, pmHelloReply, pmRequest, pmResponseOk, pmResponseError,
    pmCancel, pmEventEntry, pmEventItem, pmNotify, pmFilesystemsReady

  ProtocolFailure* = object
    code*: string
    message*: string

  ProtocolMessage* = object
    kind*: MessageKind
    role*: CoreRole
    protocols*, operations*: seq[string]
    protocol*, core*, mode*, jumpstart*: string
    id*, op*, unit*, deadline*, function*: string
    args*, result*, data*: JsonNode
    status*, event*, field*, state*, detail*: string
    error*: ProtocolFailure

proc fail(message: string) {.noreturn.} =
  var e = newException(ProtocolError, message)
  e.code = ecProtocol
  e.message = message
  raise e

proc `$`*(role: CoreRole): string =
  case role
  of crAdapter: "adapter"
  of crSupervisor: "supervisor"
  of crRunner: "runner"

proc parseRole(value: string): CoreRole =
  case value
  of "adapter": crAdapter
  of "supervisor": crSupervisor
  of "runner": crRunner
  else: fail("unknown handshake role: " & value)

proc objectNode(name: string; node: JsonNode): JsonNode =
  if node.isNil or node.kind != JObject: fail(name & " must be a JSON object")
  node

proc nonEmpty(name, value: string): string =
  if value.len == 0: fail(name & " must not be empty")
  value

proc checkKeys(node: JsonNode; required, optional: openArray[string]) =
  var allowed = initHashSet[string]()
  for key in required:
    allowed.incl key
    if not node.hasKey(key): fail("missing field: " & key)
  for key in optional: allowed.incl key
  for key, _ in node:
    if key notin allowed: fail("unknown field: " & key)

proc stringField(node: JsonNode; key: string): string =
  if not node.hasKey(key) or node[key].kind != JString:
    fail(key & " must be a string")
  node[key].getStr

proc stringList(node: JsonNode; key: string): seq[string] =
  if not node.hasKey(key) or node[key].kind != JArray:
    fail(key & " must be an array of strings")
  var seen = initHashSet[string]()
  for item in node[key]:
    if item.kind != JString or item.getStr.len == 0:
      fail(key & " must contain non-empty strings")
    if item.getStr in seen: fail(key & " must not contain duplicates")
    seen.incl item.getStr
    result.add item.getStr

proc formatDeadline*(deadline: Time): string =
  ## RFC 3339 UTC timestamp for request `deadline` (§16.2, §17.3), such as
  ## `2026-10-16T12:00:30Z`. Sub-second precision is truncated, so the
  ## advertised deadline is never later than the real one.
  deadline.utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

proc deadlineAfter*(timeoutMs: int64; now = getTime()): string =
  ## Deadline of an operation whose `timeout` (§13.1) starts now.
  formatDeadline(now + initDuration(milliseconds = timeoutMs))

proc digitsAt(text: string; start, count: int): bool =
  if start + count > text.len: return false
  for i in start ..< start + count:
    if text[i] notin {'0'..'9'}: return false
  true

proc parseDeadline*(text: string): Time =
  ## Strict RFC 3339 `date-time` (section 5.6): full date, `T`, full time with
  ## optional fraction, and `Z` or a numeric offset.
  template bad() = fail("deadline must be an RFC 3339 timestamp")
  if text.len < 20 or not digitsAt(text, 0, 4) or text[4] != '-' or
      not digitsAt(text, 5, 2) or text[7] != '-' or not digitsAt(text, 8, 2) or
      text[10] notin {'T', 't'} or not digitsAt(text, 11, 2) or text[13] != ':' or
      not digitsAt(text, 14, 2) or text[16] != ':' or not digitsAt(text, 17, 2):
    bad()
  var i = 19
  var fractionNs = 0
  if i < text.len and text[i] == '.':
    inc i
    let start = i
    while i < text.len and text[i] in {'0'..'9'}: inc i
    if i == start: bad()
    var digits = text[start ..< min(i, start + 9)]
    while digits.len < 9: digits.add '0'
    fractionNs = parseInt(digits)
  var offsetSeconds = 0
  if i < text.len and text[i] in {'Z', 'z'}:
    inc i
  elif i < text.len and text[i] in {'+', '-'}:
    if not digitsAt(text, i + 1, 2) or i + 3 >= text.len or text[i + 3] != ':' or
        not digitsAt(text, i + 4, 2):
      bad()
    let hours = parseInt(text[i + 1 .. i + 2])
    let minutes = parseInt(text[i + 4 .. i + 5])
    if hours > 23 or minutes > 59: bad()
    offsetSeconds = (hours * 3600 + minutes * 60) * (if text[i] == '+': 1 else: -1)
    i += 6
  else: bad()
  if i != text.len: bad()
  let year = parseInt(text[0 .. 3])
  let month = parseInt(text[5 .. 6])
  let day = parseInt(text[8 .. 9])
  let hour = parseInt(text[11 .. 12])
  let minute = parseInt(text[14 .. 15])
  let second = parseInt(text[17 .. 18])
  if month notin 1 .. 12 or hour > 23 or minute > 59 or second > 60: bad()
  if day < 1 or day > getDaysInMonth(Month(month), year): bad()
  # RFC 3339 permits a leap second; Time cannot represent it, so clamp.
  let dt = dateTime(year, Month(month), MonthdayRange(day), HourRange(hour),
    MinuteRange(minute), SecondRange(min(second, 59)), zone = utc())
  dt.toTime - initDuration(seconds = offsetSeconds) + initDuration(nanoseconds = fractionNs)

proc validDeadline*(text: string): bool =
  try:
    discard parseDeadline(text)
    true
  except ProtocolError:
    false

proc helloOffer*(role: CoreRole; core, mode, jumpstart: string;
                 protocols: seq[string] = @[CoreProtocol]): ProtocolMessage =
  if protocols.len == 0: fail("protocols must not be empty")
  var offered = initHashSet[string]()
  for protocol in protocols:
    if protocol.len == 0 or protocol in offered: fail("protocols must contain unique non-empty strings")
    offered.incl protocol
  if mode notin ["system", "user"]: fail("mode must be system or user")
  result = ProtocolMessage(kind: pmHelloOffer, role: role, protocols: protocols,
    core: nonEmpty("core", core), mode: nonEmpty("mode", mode),
    jumpstart: nonEmpty("jumpstart", jumpstart))

proc helloReply*(role: CoreRole; operations: seq[string] = @[];
                 protocol = CoreProtocol): ProtocolMessage =
  var declared = initHashSet[string]()
  for op in operations:
    if not validOperationName(op): fail("invalid operation name: " & op)
    if op in declared: fail("operations must not contain duplicates")
    declared.incl op
  if role != crAdapter and operations.len != 0:
    fail("only adapter handshakes carry operations")
  result = ProtocolMessage(kind: pmHelloReply, role: role,
    protocol: nonEmpty("protocol", protocol), operations: operations)

proc request*(id, op, unit: string; args: JsonNode; deadline: string;
              function = ""): ProtocolMessage =
  if not validOperationName(op): fail("invalid operation name: " & op)
  # §17.3 permits an empty unit for operations that are not unit-addressed,
  # such as `core.*` verification operations and `env`/`log` globals.
  if unit.len > 0 and not validUnitName(unit): fail("invalid unit name")
  discard parseDeadline(deadline)
  result = ProtocolMessage(kind: pmRequest, id: nonEmpty("id", id),
    op: op, unit: unit, args: objectNode("args", args),
    deadline: deadline, function: function)

proc okResponse*(id: string; value: JsonNode): ProtocolMessage =
  ProtocolMessage(kind: pmResponseOk, id: nonEmpty("id", id),
    status: "ok", result: objectNode("result", value))

proc errorResponse*(id, code, message: string): ProtocolMessage =
  ProtocolMessage(kind: pmResponseError, id: nonEmpty("id", id),
    status: "error", error: ProtocolFailure(code: nonEmpty("code", code),
    message: nonEmpty("message", message)))

proc cancel*(id: string): ProtocolMessage =
  ProtocolMessage(kind: pmCancel, id: nonEmpty("id", id))

proc entryEvent*(id: string; data: JsonNode): ProtocolMessage =
  ProtocolMessage(kind: pmEventEntry, id: nonEmpty("id", id), event: "entry",
    data: objectNode("data", data))

proc itemEvent*(id, field: string; data: JsonNode): ProtocolMessage =
  ProtocolMessage(kind: pmEventItem, id: nonEmpty("id", id), event: "item",
    field: nonEmpty("field", field), data: data)

proc notification*(unit, state: string; detail = ""): ProtocolMessage =
  if not validUnitName(unit): fail("invalid unit name")
  if state notin UnitStates: fail("unknown unit state: " & state)
  if detail.len > 512: fail("notification detail exceeds 512 bytes")
  if state == "unknown" and detail.len == 0: fail("unknown state requires detail")
  ProtocolMessage(kind: pmNotify, unit: unit, state: state,
    detail: detail)

proc filesystemsReady*(): ProtocolMessage =
  ProtocolMessage(kind: pmFilesystemsReady)

proc toJson*(message: ProtocolMessage): JsonNode =
  result = newJObject()
  template put(key: string; value: untyped) = result[key] = %(value)
  case message.kind
  of pmHelloOffer:
    put("type", "hello"); put("protocols", message.protocols)
    put("role", $message.role); put("core", message.core); put("mode", message.mode)
    put("jumpstart", message.jumpstart)
  of pmHelloReply:
    put("type", "hello"); put("protocol", message.protocol); put("role", $message.role)
    if message.role == crAdapter: put("operations", message.operations)
  of pmRequest:
    put("type", "request"); put("id", message.id); put("op", message.op)
    put("unit", message.unit)
    result["args"] = message.args; put("deadline", message.deadline)
    if message.function.len != 0: put("function", message.function)
  of pmResponseOk:
    put("type", "response"); put("id", message.id); put("status", "ok")
    result["result"] = message.result
  of pmResponseError:
    put("type", "response"); put("id", message.id); put("status", "error")
    result["error"] = %*{"code": message.error.code, "message": message.error.message}
  of pmCancel:
    put("type", "cancel"); put("id", message.id)
  of pmEventEntry, pmEventItem:
    put("type", "event"); put("id", message.id); put("event", message.event)
    if message.kind == pmEventItem: put("field", message.field)
    result["data"] = message.data
  of pmNotify:
    put("type", "notify"); put("unit", message.unit); put("state", message.state)
    if message.detail.len != 0: put("detail", message.detail)
  of pmFilesystemsReady:
    put("type", "filesystems-ready")

proc encodeLine*(message: ProtocolMessage): string =
  result = $message.toJson & "\n"
  if result.len - 1 > MaxProtocolLineBytes:
    fail("protocol line exceeds 1 MiB")

proc parseLine*(line: string): ProtocolMessage =
  var payload = line
  if payload.endsWith("\r\n"): payload.setLen(payload.len - 2)
  elif payload.endsWith("\n"): payload.setLen(payload.len - 1)
  if payload.len > MaxProtocolLineBytes: fail("protocol line exceeds 1 MiB")
  if payload.len == 0: fail("empty protocol line")
  if '\n' in payload or '\r' in payload: fail("protocol input contains multiple lines")
  if payload.validateUtf8 != -1: fail("protocol line is not UTF-8")
  var node: JsonNode
  try: node = parseJson(payload)
  except JsonParsingError as e: fail("malformed JSON: " & e.msg)
  if node.kind != JObject: fail("protocol message must be a JSON object")
  if not node.hasKey("type") or node["type"].kind != JString:
    fail("type must be a string")
  case node["type"].getStr
  of "hello":
    if node.hasKey("protocols"):
      checkKeys(node, ["type", "protocols", "role", "core", "mode", "jumpstart"], [])
      result = helloOffer(parseRole(stringField(node, "role")), stringField(node, "core"),
        stringField(node, "mode"), stringField(node, "jumpstart"), stringList(node, "protocols"))
    else:
      checkKeys(node, ["type", "protocol", "role"], ["operations"])
      let role = parseRole(stringField(node, "role"))
      if role == crAdapter and not node.hasKey("operations"): fail("adapter hello requires operations")
      if role != crAdapter and node.hasKey("operations"): fail("non-adapter hello must omit operations")
      result = helloReply(role, if node.hasKey("operations"): stringList(node, "operations") else: @[],
        stringField(node, "protocol"))
  of "request":
    checkKeys(node, ["type", "id", "op", "unit", "args", "deadline"], ["function"])
    result = request(stringField(node, "id"), stringField(node, "op"),
      stringField(node, "unit"), node["args"],
      stringField(node, "deadline"), if node.hasKey("function"): stringField(node, "function") else: "")
  of "response":
    if not node.hasKey("status") or node["status"].kind != JString: fail("status must be a string")
    case node["status"].getStr
    of "ok":
      checkKeys(node, ["type", "id", "status", "result"], [])
      result = okResponse(stringField(node, "id"), node["result"])
    of "error":
      checkKeys(node, ["type", "id", "status", "error"], [])
      discard objectNode("error", node["error"]); checkKeys(node["error"], ["code", "message"], [])
      result = errorResponse(stringField(node, "id"), stringField(node["error"], "code"), stringField(node["error"], "message"))
    else: fail("unknown response status")
  of "cancel":
    checkKeys(node, ["type", "id"], []); result = cancel(stringField(node, "id"))
  of "event":
    if not node.hasKey("event") or node["event"].kind != JString: fail("event must be a string")
    case node["event"].getStr
    of "entry":
      checkKeys(node, ["type", "id", "event", "data"], [])
      result = entryEvent(stringField(node, "id"), node["data"])
    of "item":
      checkKeys(node, ["type", "id", "event", "field", "data"], [])
      result = itemEvent(stringField(node, "id"), stringField(node, "field"), node["data"])
    else: fail("unknown event")
  of "notify":
    checkKeys(node, ["type", "unit", "state"], ["detail"])
    result = notification(stringField(node, "unit"), stringField(node, "state"),
      if node.hasKey("detail"): stringField(node, "detail") else: "")
  of "filesystems-ready":
    checkKeys(node, ["type"], []); result = filesystemsReady()
  else: fail("unknown message type")

proc validateHandshake*(offer, reply: ProtocolMessage;
                        routedOperations: openArray[string]) =
  if offer.kind != pmHelloOffer or reply.kind != pmHelloReply:
    fail("expected hello offer and hello reply")
  if reply.protocol notin offer.protocols: fail("peer selected a protocol that was not offered")
  if reply.role != offer.role: fail("handshake role mismatch")
  if reply.role == crAdapter:
    var expected, actual = initHashSet[string]()
    for op in routedOperations: expected.incl op
    for op in reply.operations: actual.incl op
    if actual != expected: fail("adapter operations do not match routed operations")
  elif reply.operations.len != 0:
    fail("non-adapter hello must omit operations")

# ---------------------------------------------------------------------------
# Result schema (§12, §16.3, §17.3)

proc itemSchema(operation, field: string): Option[seq[FieldSpec]] =
  ## The registry's closed item shape for a list-of-objects field (§12), or
  ## none for core-defined objects (`errors`, `diagnostics`, `failed`).
  ## `log.follow` streams §12.10 entries although it has no result field.
  if field == "entries" and operation == "log.follow":
    return some(logEntryFields(CurrentManifestVersion))
  let spec = resultField(CurrentManifestVersion, operation, field)
  if spec.isSome and spec.get.kind == vkObjectList and spec.get.itemShape == isRegistry:
    return some(spec.get.itemFields)
  none(seq[FieldSpec])

proc objectItemFields*(operation, field: string): Option[seq[string]] =
  ## Keys of the objects in a list-of-objects result field when §12 defines
  ## them (from the registry). Other object lists are core-defined objects.
  let schema = itemSchema(operation, field)
  if schema.isNone: return none(seq[string])
  var keys: seq[string]
  for item in schema.get: keys.add item.name
  some(keys)

proc validStatusToken*(value: string): bool =
  ## §12.11 `substate` and `result`: 1 to 64 bytes of lowercase ASCII letters,
  ## digits, and `-`.
  if value.len == 0 or value.len > MaxStatusTokenBytes: return false
  for c in value:
    if c notin {'a'..'z', '0'..'9', '-'}: return false
  true

proc checkClosedValue(context, key, value: string) =
  case key
  of "since":
    if not validDeadline(value): fail(context & ": since must be an RFC 3339 timestamp")
  of "substate", "result":
    if not validStatusToken(value):
      fail(context & ": " & key & " must be 1 to 64 bytes of lowercase letters, digits, and '-'")
  of "state":
    if value notin UnitStates: fail(context & ": unknown unit state: " & value)
  of "enablement":
    if value notin EnablementStates: fail(context & ": unknown enablement: " & value)
  of "level":
    if value notin LogLevels: fail(context & ": unknown log level: " & value)
  of "detail":
    if value.len > MaxDetailBytes: fail(context & ": detail exceeds 512 bytes")
  else: discard

proc validateObjectItem*(operation, field: string; item: JsonNode) =
  ## One element of a list-of-objects field, from a response or an `item`
  ## event (§17.4).
  if item.isNil or item.kind != JObject:
    fail(operation & ": " & field & " must contain objects")
  let schema = itemSchema(operation, field)
  if schema.isNone: return
  let context = operation & ": " & field
  for spec in schema.get:
    if not item.hasKey(spec.name): fail(context & " item missing " & spec.name)
  for key, value in item:
    var known = false
    for spec in schema.get:
      if spec.name != key: continue
      known = true
      case spec.kind
      of vkString:
        if value.kind != JString: fail(context & "." & key & " must be a string")
        checkClosedValue(context, key, value.getStr)
      of vkBool:
        if value.kind != JBool: fail(context & "." & key & " must be a boolean")
      of vkInt:
        if value.kind != JInt: fail(context & "." & key & " must be an integer")
      else: fail(context & "." & key & " has an unsupported item type")
    if not known: fail(context & " item has unknown key " & key)

proc validateEntry*(data: JsonNode) =
  ## `entry` event payload (§17.4, §12.10).
  validateObjectItem("log.follow", "entries", data)

proc validateResult*(operation: string; value: JsonNode;
                     manifestVersion = CurrentManifestVersion) =
  ## Validate a finished result against the registry (§16.3): unknown keys,
  ## missing required keys, and values of the wrong type raise a
  ## `ProtocolError` (`E_PROTOCOL`). Closed vocabularies (§12.10–§12.12) are
  ## part of the schema.
  let spec = findOperation(manifestVersion, operation)
  if spec.isNone: fail("result for unknown operation: " & operation)
  if value.isNil or value.kind != JObject: fail(operation & ": result must be an object")
  var known = initHashSet[string]()
  for field in spec.get.results:
    known.incl field.name
    if not value.hasKey(field.name):
      if not field.optional: fail(operation & ": missing result field " & field.name)
      continue
    let node = value[field.name]
    let context = operation & ": " & field.name
    case field.kind
    of vkString:
      if node.kind != JString: fail(context & " must be a string")
      checkClosedValue(operation, field.name, node.getStr)
    of vkBool:
      if node.kind != JBool: fail(context & " must be a boolean")
    of vkInt:
      if node.kind != JInt: fail(context & " must be an integer")
    of vkStringList:
      if node.kind != JArray: fail(context & " must be a list")
      for item in node:
        if item.kind != JString: fail(context & " must contain strings")
    of vkIntList:
      if node.kind != JArray: fail(context & " must be a list")
      for item in node:
        if item.kind != JInt: fail(context & " must contain integers")
    of vkObjectList:
      if node.kind != JArray: fail(context & " must be a list")
      for item in node: validateObjectItem(operation, field.name, item)
  for key, _ in value:
    if key notin known: fail(operation & ": unknown result field " & key)

proc resultIsValid*(operation: string; value: JsonNode): bool =
  ## Boolean adapter for callback-style validators.
  try:
    validateResult(operation, value)
    true
  except ProtocolError:
    false

proc responseFailure*(message: ProtocolMessage): (CoreErrorCode, string) =
  ## Map an error `response` to the code and message Jumpstart reports. A
  ## defined §18 code is preserved; any other code is a protocol violation.
  if message.kind != pmResponseError: fail("not an error response")
  var code: CoreErrorCode
  if tryParseErrorCode(message.error.code, code):
    (code, message.error.message)
  else:
    (ecProtocol, "backend reported undefined error code " & message.error.code &
      ": " & message.error.message)
