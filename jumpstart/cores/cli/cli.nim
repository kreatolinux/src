## Pure command construction and presentation for jumpctl (§21).
##
## This module never inspects argv, the uid, the filesystem, or a socket: it
## builds control requests (§14.5), parses the daemon's reply stream, and
## renders every §21 output. `jumpctl.nim` does the I/O.
##
## Control-socket result shapes this client relies on (the §14.5 envelope is
## `{"type":"response","status":…}`; these are the `result` objects of the
## requests the spec leaves to the implementation):
##
## * every `ok` or `error` response MAY carry `"core"` (ok: top level; error:
##   inside `error`), naming the core that handled the request. Unit requests
##   need it to print `set-default` (§21.3), native `status` text (§21.2), and
##   `jumpctl: CORE: …` diagnostics (§18) for unqualified references.
## * `core` `status`: `{"cores": [ROW…], "state_error"?: {"code","message"}}`
##   in listing order (§7.3); ROW is `{"name", "state", "stale"?: bool,
##   "error"?: {"code","message"}}` (`error` for `failed` cores, §21.10).
## * `core` `list-loaded`: `{"cores": [ROW…]}`, the loaded set (§20.1) in load
##   order; used to fan `units`/`get-default` out across cores (§21.3, §21.4).
## * `users` `list`: `{"users": [{"uid": int, "user", "sessions": int,
##   "state", "linger": bool}…]}` (§21.8).
## * `env` `list`: `{"vars": {"KEY": "VALUE"…}}` (§21.9).
## * operation results follow the registry (§12), with list fields possibly
##   delivered as `item` events (§17.4) and `log.follow` entries as `entry`
##   events.
import std/[algorithm, json, options, strutils, tables]
import ../daemon/control, ../manifest/modes
import jumpstartcore/[environment, errors, names, registry, registry_types]
from jumpstartcore/protocol import validateResult, validateObjectItem, validateEntry, validDeadline, LogLevels, UnitStates
import ../../serviceHandler/status_text

export errors

type
  CliCommandKind* = enum
    ccStart, ccStop, ccRestart, ccReload, ccKill, ccEnable, ccDisable,
    ccStatus, ccIsolate, ccSetDefault, ccGetDefault,
    ccUnitsList, ccUnitsLoad, ccUnitsValidate, ccUnitsTranslate,
    ccLogsRead, ccLogsFollow, ccLogsWrite, ccLogsRotate, ccLogsVacuum,
    ccPoweroff, ccReboot, ccHalt,
    ccUsersList, ccUsersLingerList, ccUsersLingerEnable, ccUsersLingerDisable,
    ccEnvList, ccEnvSet, ccEnvUnset, ccEnvImport,
    ccCoresList, ccCoresStatus, ccCoresEnable, ccCoresDisable,
    ccCoresLoad, ccCoresUnload, ccCoresReload, ccCoresShow, ccCoresCheck,
    ccCoresRun, ccCoresListLoaded
  CommandExecution* = enum ceLocal, ceLive, ceLiveThenLocal
  CliCommand* = object
    kind*: CliCommandKind
    unit*, core*, user*, operation*, message*: string
    values*, keys*: seq[string]
    args*: JsonNode
    signal*, target*, level*, since*, until*: string
    lines*: int
    now*, stopUnits*, resolved*, enabledOnly*, loadedOnly*: bool
    maxSize*: Option[int64]
    maxAge*: Option[string]
  CliOutput* = object
    stdout*, stderr*: string
    exitStatus*: int

  Reply* = object
    ## The final `response` line of a request (§14.5).
    ok*: bool
    result*: JsonNode
    warnings*: seq[string]
    core*: string        ## core that handled the request, if the daemon says
    code*: CoreErrorCode
    message*: string
  StreamKind* = enum skEntry, skItem, skResponse
  StreamLine* = object
    case kind*: StreamKind
    of skEntry: entry*: JsonNode
    of skItem:
      field*: string
      item*: JsonNode
    of skResponse: reply*: Reply
  ReplyCollector* = object
    ## Items received before the response, per field, in arrival order.
    items*: OrderedTable[string, seq[JsonNode]]

const
  DefaultLogLines* = 1000   ## §12.10, §21.5
  MaximumLogLines* = 10000  ## §12.10, §21.5
  ClientName* = "Jumpstart CLI"
  CoreStates* = ["unloaded", "loading", "loaded", "unloading", "failed", "degraded"]
    ## §20.1
  LoadedStates* = ["loaded", "degraded"]
    ## §20.1: the loaded set.
  UserDaemonStates* = ["running", "starting", "stopping", "failed"]
    ## §21.8

proc command*(kind: CliCommandKind): CliCommand =
  CliCommand(kind: kind, lines: DefaultLogLines)

proc execution*(cmd: CliCommand): CommandExecution =
  case cmd.kind
  of ccUsersLingerList, ccUsersLingerEnable, ccUsersLingerDisable,
      ccCoresShow, ccCoresCheck, ccCoresRun: ceLocal
  of ccCoresList:
    if cmd.loadedOnly: ceLive else: ceLocal
  of ccCoresEnable, ccCoresDisable:
    if cmd.now: ceLiveThenLocal else: ceLocal
  else: ceLive

proc isLocal*(cmd: CliCommand): bool = cmd.execution == ceLocal
proc usesDaemon*(cmd: CliCommand): bool = cmd.execution != ceLocal
proc persistsAfterLive*(cmd: CliCommand): bool = cmd.execution == ceLiveThenLocal
proc isUnitCommand*(kind: CliCommandKind): bool =
  ## §21.7: unit commands print `jumpstart:` success lines.
  kind in {ccStart, ccStop, ccRestart, ccReload, ccKill, ccEnable, ccDisable,
           ccStatus, ccIsolate, ccSetDefault, ccGetDefault}

proc allowedInMode*(kind: CliCommandKind; mode: CoreMode): bool =
  ## §21.1: power and `users` are system-mode only, `env` user-mode only.
  case kind
  of ccPoweroff, ccReboot, ccHalt, ccUsersList, ccUsersLingerList,
      ccUsersLingerEnable, ccUsersLingerDisable: mode == cmSystem
  of ccEnvList, ccEnvSet, ccEnvUnset, ccEnvImport: mode == cmUser
  else: true
proc validateMode*(cmd: CliCommand; mode: CoreMode) =
  if not allowedInMode(cmd.kind, mode):
    let which = if mode == cmSystem: "system" else: "user"
    raise newCoreError(ecUsage, "command is not available in " & which & " mode")

proc usage(message: string) {.noreturn.} = raise newCoreError(ecUsage, message)
proc protocolError(message: string; core = "") {.noreturn.} =
  raise newCoreError(ecProtocol, message, core)

proc objectArgs(cmd: CliCommand): JsonNode =
  if cmd.args.isNil: newJObject()
  elif cmd.args.kind != JObject: usage("command arguments must be an object")
  else: cmd.args.copy
proc require(value, label: string) =
  if value.len == 0: usage(label & " is required")
proc addString(n: JsonNode; key, value: string) =
  if value.len > 0: n[key] = %value

proc validateEnvKey*(key: string) =
  ## §21.9: `[A-Z_][A-Z0-9_]*`, and not HOME, USER, LOGNAME, SHELL, JUMPSTART_*.
  if not validEnvironmentName(key): usage("invalid environment variable name: " & key)
  if isProtectedUserVariable(key): usage("protected environment variable: " & key)

proc splitAssignment*(assignment: string): (string, string) =
  let separator = assignment.find('=')
  if separator <= 0: usage("expected KEY=VALUE: " & assignment)
  (assignment[0 ..< separator], assignment[separator + 1 .. ^1])

proc unitPart*(reference: string): string =
  ## The unit name of a unit reference (§14.2): the text after the first `/`.
  let slash = reference.find('/')
  if slash < 0: reference else: reference[slash + 1 .. ^1]
proc corePart*(reference: string): string =
  ## The core of a qualified unit reference, or "".
  let slash = reference.find('/')
  if slash < 0: "" else: reference[0 ..< slash]

proc buildRequest*(cmd: CliCommand; version: string;
                   clientName = ClientName): ControlRequest =
  ## The one request a daemon command sends (§14.5). Fan-out commands send
  ## one request per core; their `core` is set by the caller.
  if not cmd.usesDaemon:
    usage("local command has no control request")
  let ci = ClientInfo(name: clientName, version: version)
  case cmd.kind
  of ccStart, ccStop, ccRestart, ccReload, ccKill, ccEnable, ccDisable,
      ccStatus, ccIsolate, ccSetDefault, ccUnitsValidate, ccUnitsTranslate:
    require(cmd.unit, "unit")
    let action = case cmd.kind
      of ccStart: "start"
      of ccStop: "stop"
      of ccRestart: "restart"
      of ccReload: "reload"
      of ccKill: "kill"
      of ccEnable: "enable"
      of ccDisable: "disable"
      of ccStatus: "status"
      of ccIsolate: "isolate"
      of ccSetDefault: "set-default"
      of ccUnitsValidate: "validate"
      else: "translate"
    var args = objectArgs(cmd)
    if cmd.kind == ccKill:
      # §14.4: `signal` defaults to SIGTERM.
      args["signal"] = %(if cmd.signal.len == 0: "SIGTERM" else: cmd.signal)
    if cmd.kind in {ccEnable, ccDisable}:
      # §14.4: `target` is a bare unit name of the same core.
      if '/' in cmd.target: usage("--target takes a unit name, not a unit reference")
      args["now"] = %cmd.now
      args.addString("target", cmd.target)
    result = ControlRequest(kind: rkService, client: ci,
      service: ServiceRequest(name: cmd.unit, action: action,
        now: (if cmd.kind in {ccEnable, ccDisable}: some($cmd.now) else: none(string)),
        args: args))
  of ccGetDefault, ccUnitsList, ccUnitsLoad, ccLogsRotate, ccLogsVacuum:
    require(cmd.core, "core")
    let opName = case cmd.kind
      of ccGetDefault: "target.get-default"
      of ccUnitsList: "unit.list"
      of ccUnitsLoad: "unit.load"
      of ccLogsRotate: "log.rotate"
      else: "log.vacuum"
    var args = objectArgs(cmd)
    if cmd.kind == ccLogsVacuum:
      if cmd.maxSize.isNone and cmd.maxAge.isNone:
        usage("logs vacuum requires --max-size or --max-age")
      if cmd.maxSize.isSome: args["max_size"] = %cmd.maxSize.get
      if cmd.maxAge.isSome: args["max_age"] = %cmd.maxAge.get
    result = ControlRequest(kind: rkOp, client: ci,
      op: OpRequest(core: cmd.core, name: opName, args: args))
  of ccLogsRead, ccLogsFollow, ccLogsWrite:
    let action = if cmd.kind == ccLogsRead: "log-read"
                 elif cmd.kind == ccLogsFollow: "log-follow" else: "log-write"
    let opName = action.replace("-", ".")
    var args = objectArgs(cmd)
    for (name, value) in [("--since", cmd.since), ("--until", cmd.until)]:
      if value.len > 0 and not validDeadline(value):
        usage(name & " must be an RFC 3339 timestamp")
    args.addString("since", cmd.since)
    if cmd.kind == ccLogsRead:
      args.addString("until", cmd.until)
      if cmd.lines < 1 or cmd.lines > MaximumLogLines:
        usage("--lines must be between 1 and 10000")
      args["lines"] = %cmd.lines
    if cmd.kind == ccLogsWrite:
      require(cmd.level, "--level"); require(cmd.message, "message")
      if cmd.level notin LogLevels:
        usage("--level must be one of " & LogLevels.join(", "))
      args["level"] = %cmd.level; args["message"] = %cmd.message
    if cmd.unit.len > 0:
      if cmd.core.len > 0: usage("--core cannot be combined with UNIT; use CORE/UNIT")
      result = ControlRequest(kind: rkService, client: ci,
        service: ServiceRequest(name: cmd.unit, action: action, now: none(string), args: args))
    else:
      # §21.5: without UNIT, --core is required.
      if cmd.core.len == 0: usage("--core is required without UNIT")
      result = ControlRequest(kind: rkOp, client: ci,
        op: OpRequest(core: cmd.core, name: opName, args: args))
  of ccPoweroff, ccReboot, ccHalt:
    let action = if cmd.kind == ccPoweroff: "poweroff"
                 elif cmd.kind == ccReboot: "reboot" else: "halt"
    result = ControlRequest(kind: rkPower, client: ci, power: PowerRequest(action: action))
  of ccUsersList:
    result = ControlRequest(kind: rkUsers, client: ci, users: UsersRequest(action: "list"))
  of ccEnvList, ccEnvSet, ccEnvUnset, ccEnvImport:
    var vars = newJObject()
    var action = "list"
    case cmd.kind
    of ccEnvSet, ccEnvImport:
      # `import` copies values from jumpctl's own environment (§21.9); the
      # caller resolves them into `values`, and the daemon stores them as a
      # `set`.
      action = "set"
      if cmd.values.len == 0: usage("at least one KEY=VALUE is required")
      for assignment in cmd.values:
        let (key, value) = splitAssignment(assignment)
        validateEnvKey(key)
        if '\0' in value: usage("environment values cannot contain NUL")
        vars[key] = %value
    of ccEnvUnset:
      # `env.vars` is a string map (§14.5); `unset` names keys, whose values
      # are empty.
      action = "unset"
      if cmd.keys.len == 0: usage("at least one KEY is required")
      for key in cmd.keys:
        validateEnvKey(key)
        vars[key] = %""
    else: discard
    result = ControlRequest(kind: rkEnv, client: ci, env: EnvRequest(action: action, vars: vars))
  of ccCoresStatus, ccCoresLoad, ccCoresUnload, ccCoresReload,
      ccCoresEnable, ccCoresDisable, ccCoresList, ccCoresListLoaded:
    let action = case cmd.kind
      of ccCoresStatus, ccCoresList: "status"
      of ccCoresLoad, ccCoresEnable: "load"
      of ccCoresUnload, ccCoresDisable: "unload"
      of ccCoresReload: "reload"
      else: "list-loaded"
    if cmd.kind notin {ccCoresStatus, ccCoresList, ccCoresListLoaded}: require(cmd.core, "core")
    let stop = cmd.kind in {ccCoresUnload, ccCoresReload, ccCoresDisable}
    result = ControlRequest(kind: rkCore, client: ci,
      core: CoreRequest(
        name: (if cmd.core.len > 0 and cmd.kind != ccCoresList: some(cmd.core) else: none(string)),
        action: action, stopUnits: (if stop: some(cmd.stopUnits) else: none(bool))))
  of ccUsersLingerList, ccUsersLingerEnable, ccUsersLingerDisable,
      ccCoresShow, ccCoresCheck, ccCoresRun:
    usage("local command has no control request")

# ---------------------------------------------------------------------------
# Reply stream (§14.5, §17.4)

proc stringAt(n: JsonNode; key, where: string): string =
  if not n.hasKey(key) or n[key].kind != JString:
    protocolError(where & "." & key & " must be a string")
  n[key].getStr

proc parseStreamLine*(line: string): StreamLine =
  ## One line from the daemon: an `event` (`entry` or `item`) or the final
  ## `response`. Fields this client does not use are ignored.
  var payload = line
  if payload.endsWith("\n"): payload.setLen(payload.len - 1)
  if payload.endsWith("\r"): payload.setLen(payload.len - 1)
  if payload.len > MaxControlLineBytes: protocolError("daemon line exceeds 1 MiB")
  var n: JsonNode
  try: n = parseJson(payload)
  except CatchableError as e: protocolError("malformed daemon line: " & e.msg)
  if n.kind != JObject: protocolError("daemon line must be an object")
  case stringAt(n, "type", "line")
  of "event":
    if not n.hasKey("data"): protocolError("event without data")
    case stringAt(n, "event", "event")
    of "entry": result = StreamLine(kind: skEntry, entry: n["data"])
    of "item":
      result = StreamLine(kind: skItem, field: stringAt(n, "field", "event"), item: n["data"])
    else: protocolError("unknown event: " & n["event"].getStr)
  of "response":
    var reply = Reply()
    case stringAt(n, "status", "response")
    of "ok":
      reply.ok = true
      reply.result = if n.hasKey("result"): n["result"] else: newJObject()
      if reply.result.kind != JObject: protocolError("response.result must be an object")
      if n.hasKey("warnings"):
        if n["warnings"].kind != JArray: protocolError("response.warnings must be a list")
        for warning in n["warnings"]:
          if warning.kind != JString: protocolError("response.warnings must contain strings")
          reply.warnings.add warning.getStr
      if n.hasKey("core"): reply.core = stringAt(n, "core", "response")
    of "error":
      if not n.hasKey("error") or n["error"].kind != JObject:
        protocolError("error response without error object")
      let e = n["error"]
      let name = stringAt(e, "code", "response.error")
      if not tryParseErrorCode(name, reply.code):
        protocolError("daemon reported an undefined error code: " & name)
      reply.message = stringAt(e, "message", "response.error")
      if e.hasKey("core"): reply.core = stringAt(e, "core", "response.error")
    else: protocolError("unknown response status")
    result = StreamLine(kind: skResponse, reply: reply)
  else: protocolError("unknown daemon line type")

proc add*(collector: var ReplyCollector; line: StreamLine) =
  if line.kind == skItem:
    collector.items.mgetOrPut(line.field, @[]).add line.item

proc merged*(collector: ReplyCollector; reply: Reply): JsonNode =
  ## §17.4: items are appended to their field in arrival order, before any
  ## elements the response itself contains.
  result = if reply.result.isNil: newJObject() else: reply.result.copy
  for field, items in collector.items:
    var list = newJArray()
    for item in items: list.add item
    if result.hasKey(field):
      if result[field].kind != JArray: protocolError("item field is not a list: " & field)
      for element in result[field]: list.add element
    result[field] = list

# ---------------------------------------------------------------------------
# Presentation

proc line(value: string): string =
  if value.len == 0: "" else: value & "\n"
proc oneLine(text: string): string =
  text.replace("\r", " ").replace("\n", " ")
proc scalar*(n: JsonNode): string =
  case n.kind
  of JString: n.getStr
  of JBool: $n.getBool
  of JInt: $n.getBiggestInt
  of JFloat: $n.getFloat
  of JNull: "null"
  else: $n

proc reject(core, message: string) {.noreturn.} = protocolError(message, core)

proc checkOperationResult*(operation: string; value: JsonNode; core = "") =
  ## Daemon results for core operations follow the registry (§12).
  try: validateResult(operation, value)
  except CoreError as e: reject(core, e.msg)

proc formatLogEntry*(entry: JsonNode; core = ""): string =
  ## §21.5: `TIME LEVEL UNIT MESSAGE`. A global entry's empty unit prints `-`.
  try: validateEntry(entry)
  except CoreError as e: reject(core, e.msg)
  let unit = entry["unit"].getStr
  entry["time"].getStr & " " & entry["level"].getStr & " " &
    (if unit.len == 0: "-" else: unit) & " " & oneLine(entry["message"].getStr) & "\n"

proc formatCoreObject*(item: JsonNode): string =
  ## One core-defined object (`unit.load` errors, `unit.validate`
  ## diagnostics): `NAME: CODE: MESSAGE` for the keys that are present, then
  ## any other keys as ` KEY=VALUE` in byte order.
  var parts: seq[string]
  for key in ["name", "code", "message"]:
    if item.hasKey(key): parts.add oneLine(scalar(item[key]))
  result = parts.join(": ")
  var others: seq[string]
  for key, _ in item:
    if key notin ["name", "code", "message"]: others.add key
  others.sort(system.cmp[string])
  for key in others:
    if result.len > 0: result.add " "
    result.add key & "=" & oneLine(scalar(item[key]))

proc formatStatus*(value: JsonNode; owner: string): string =
  ## §21.2: native status text for `serviceHandler` units, the §12.11 state
  ## otherwise.
  let state = if owner == "serviceHandler": nativeStatusText(value)
              else: value{"state"}.getStr
  result = "jumpstart: unit is reporting status as '" & state & "'\n"
  # §12.11, §21.2: the optional fields follow as `KEY: VALUE` lines. Native
  # status never carries them, so native output is unchanged.
  if owner != "serviceHandler":
    for key in ["since", "substate", "result"]:
      if value.kind == JObject and value.hasKey(key) and value[key].kind == JString:
        result.add key & ": " & value[key].getStr & "\n"

proc formatUnitSuccess*(cmd: CliCommand; value: JsonNode; owner: string): string =
  ## §21.2, §21.3: success lines of unit commands, with names as typed.
  case cmd.kind
  of ccStart: line("jumpstart: started unit " & cmd.unit)
  of ccStop: line("jumpstart: stopped unit " & cmd.unit)
  of ccRestart: line("jumpstart: restarted unit " & cmd.unit)
  of ccReload: line("jumpstart: reloaded unit " & cmd.unit)
  of ccKill: line("jumpstart: killed unit " & cmd.unit)
  of ccEnable: line("jumpstart: enabled unit " & cmd.unit)
  of ccDisable: line("jumpstart: disabled unit " & cmd.unit)
  of ccIsolate: line("jumpstart: isolated unit " & cmd.unit)
  of ccStatus: formatStatus(value, owner)
  of ccSetDefault:
    if owner.len == 0: reject("", "response does not name the core of " & cmd.unit)
    line("jumpstart: default target of " & owner & " is now " & unitPart(cmd.unit))
  else: ""

proc formatUnitRows*(core: string; value: JsonNode): string =
  ## §21.4 `units list`: `CORE/UNIT SUBSYSTEM ENABLEMENT`, in the core's order.
  checkOperationResult("unit.list", value, core)
  for item in value["units"]:
    result.add core & "/" & item["name"].getStr & " " & item["subsystem"].getStr &
      " " & item["enablement"].getStr & "\n"

proc formatUnitsLoad*(core: string; value: JsonNode): string =
  ## §21.4 `units load`: `CORE: loaded N`, then each reported error.
  checkOperationResult("unit.load", value, core)
  result = core & ": loaded " & $value["loaded"].getBiggestInt & "\n"
  for item in value["errors"]: result.add core & ": " & formatCoreObject(item) & "\n"

proc formatValidate*(value: JsonNode; core = ""): CliOutput =
  ## §21.4 `units validate`: the diagnostics; exit 1 when the unit is invalid.
  checkOperationResult("unit.validate", value, core)
  for item in value["diagnostics"]: result.stdout.add formatCoreObject(item) & "\n"
  result.exitStatus = if value["valid"].getBool: 0 else: 1

proc formatTranslate*(value: JsonNode; core = ""): string =
  ## §21.4 `units translate`: the decfile, verbatim.
  checkOperationResult("unit.translate", value, core)
  value["decfile"].getStr

proc formatGetDefault*(core: string; value: JsonNode): string =
  ## §21.3: `CORE/NAME`.
  checkOperationResult("target.get-default", value, core)
  core & "/" & value["name"].getStr & "\n"

proc formatLogEntries*(value: JsonNode; core = ""): string =
  checkOperationResult("log.read", value, core)
  for entry in value["entries"]: result.add formatLogEntry(entry, core)

proc errorObject(row: JsonNode; key, where: string): (CoreErrorCode, string) =
  let e = row[key]
  if e.kind != JObject: protocolError(where & "." & key & " must be an object")
  var code: CoreErrorCode
  let name = stringAt(e, "code", where & "." & key)
  if not tryParseErrorCode(name, code): protocolError("undefined error code: " & name)
  (code, stringAt(e, "message", where & "." & key))

proc coreRows*(value: JsonNode): seq[JsonNode] =
  ## The validated ROW objects of a `core` `status`/`list-loaded` result.
  if value.isNil or not value.hasKey("cores") or value["cores"].kind != JArray:
    protocolError("core result must contain a cores list")
  for row in value["cores"]:
    if row.kind != JObject: protocolError("core rows must be objects")
    discard stringAt(row, "name", "core row")
    if stringAt(row, "state", "core row") notin CoreStates:
      protocolError("unknown core state: " & row["state"].getStr)
    if row.hasKey("stale") and row["stale"].kind != JBool:
      protocolError("core row stale must be a boolean")
    if row.hasKey("error"): discard errorObject(row, "error", "core row")
    result.add row

proc formatCoresStatus*(value: JsonNode): string =
  ## §21.10: `CORE STATE[ stale][ E_CODE: message]`, preceded by
  ## `E_STATE: message` when the enabled state is invalid.
  if value.hasKey("state_error"):
    let (code, message) = errorObject(value, "state_error", "core result")
    result.add errorName(code) & ": " & oneLine(message) & "\n"
  for row in coreRows(value):
    var text = row["name"].getStr & " " & row["state"].getStr
    if row.hasKey("stale") and row["stale"].getBool: text.add " stale"
    if row["state"].getStr == "failed" and row.hasKey("error"):
      let (code, message) = errorObject(row, "error", "core row")
      text.add " " & errorName(code) & ": " & oneLine(message)
    result.add text & "\n"

proc formatLoadedCores*(value: JsonNode): string =
  ## §21.13 `cores list --loaded`: the loaded set, in listing order.
  for row in coreRows(value):
    if row["state"].getStr in LoadedStates: result.add row["name"].getStr & "\n"

proc loadedCoreNames*(value: JsonNode): seq[string] =
  ## `list-loaded`: the loaded set in load order.
  for row in coreRows(value):
    if row["state"].getStr in LoadedStates: result.add row["name"].getStr

proc formatUsers*(value: JsonNode): string =
  ## §21.8: `UID USER SESSIONS STATE LINGER`.
  if not value.hasKey("users") or value["users"].kind != JArray:
    protocolError("users result must contain a users list")
  for row in value["users"]:
    if row.kind != JObject: protocolError("user rows must be objects")
    if not row.hasKey("uid") or row["uid"].kind != JInt: protocolError("user uid must be an integer")
    if not row.hasKey("sessions") or row["sessions"].kind != JInt:
      protocolError("user sessions must be an integer")
    if not row.hasKey("linger") or row["linger"].kind != JBool:
      protocolError("user linger must be a boolean")
    # An unfamiliar state is printed as given: one odd row must not fail the
    # whole listing (§21.8 names the states the daemon sends today).
    let state = stringAt(row, "state", "user row")
    result.add $row["uid"].getBiggestInt & " " & stringAt(row, "user", "user row") & " " &
      $row["sessions"].getBiggestInt & " " & state & " " &
      (if row["linger"].getBool: "linger" else: "-") & "\n"

proc formatEnvironment*(value: JsonNode): string =
  ## §21.9: `KEY=VALUE`, in byte order of key.
  if not value.hasKey("vars") or value["vars"].kind != JObject:
    protocolError("env result must contain a vars object")
  var keys: seq[string]
  for key, item in value["vars"]:
    if item.kind != JString: protocolError("env values must be strings")
    keys.add key
  keys.sort(system.cmp[string])
  for key in keys: result.add key & "=" & value["vars"][key].getStr & "\n"

proc formatEnvChange*(cmd: CliCommand): string =
  ## Success lines of `env set/unset/import`, one per key in byte order.
  var keys: seq[string]
  let verb = case cmd.kind
    of ccEnvSet: "set"
    of ccEnvUnset: "unset"
    else: "imported"
  if cmd.kind == ccEnvUnset: keys = cmd.keys
  else:
    for assignment in cmd.values: keys.add splitAssignment(assignment)[0]
  keys.sort(system.cmp[string])
  for key in keys: result.add "jumpctl: " & verb & " " & key & "\n"

proc formatRunResult*(operation: string; value: JsonNode): string =
  ## §21.15: `KEY: VALUE` per result field, in registry order.
  let spec = findOperation(CurrentManifestVersion, operation)
  if spec.isNone or value.isNil or value.kind != JObject: return ""
  for field in spec.get.results:
    if not value.hasKey(field.name): continue
    let node = value[field.name]
    var text = ""
    if node.kind == JArray:
      var parts: seq[string]
      for item in node:
        parts.add(if item.kind == JObject: formatCoreObject(item) else: scalar(item))
      text = parts.join(", ")
    else: text = scalar(node)
    result.add field.name & ": " & oneLine(text) & "\n"

proc formatSuccess*(cmd: CliCommand; value: JsonNode = nil; owner = ""): string =
  ## Success output of single-request commands.
  let payload = if value.isNil: newJObject() else: value
  case cmd.kind
  of ccStart, ccStop, ccRestart, ccReload, ccKill, ccEnable, ccDisable,
      ccStatus, ccIsolate, ccSetDefault:
    formatUnitSuccess(cmd, payload, owner)
  of ccPoweroff: line("jumpctl: powering off")
  of ccReboot: line("jumpctl: rebooting")
  of ccHalt: line("jumpctl: halting")
  of ccCoresEnable: line("jumpctl: enabled core " & cmd.core)
  of ccCoresDisable: line("jumpctl: disabled core " & cmd.core)
  of ccCoresLoad: line("jumpctl: loaded core " & cmd.core)
  of ccCoresUnload: line("jumpctl: unloaded core " & cmd.core)
  of ccCoresReload: line("jumpctl: reloaded core " & cmd.core)
  of ccCoresStatus: formatCoresStatus(payload)
  of ccCoresList: formatLoadedCores(payload)
  of ccUnitsList: formatUnitRows(cmd.core, payload)
  of ccUnitsLoad: formatUnitsLoad(cmd.core, payload)
  of ccUnitsTranslate: formatTranslate(payload, owner)
  of ccGetDefault: formatGetDefault(cmd.core, payload)
  of ccLogsRead: formatLogEntries(payload, owner)
  of ccLogsWrite: line("jumpctl: wrote log entry")
  of ccLogsRotate: line("jumpctl: rotated logs of core " & cmd.core)
  of ccLogsVacuum:
    checkOperationResult("log.vacuum", payload, cmd.core)
    line("jumpctl: vacuumed logs of core " & cmd.core & ", freed " &
      $payload["freed"].getBiggestInt & " bytes")
  of ccUsersList: formatUsers(payload)
  of ccEnvList: formatEnvironment(payload)
  of ccEnvSet, ccEnvUnset, ccEnvImport: formatEnvChange(cmd)
  of ccCoresRun: formatRunResult(cmd.operation, payload)
  else: ""

proc diagnosticCore*(cmd: CliCommand; reply: Reply): string =
  ## §18: the core a diagnostic names — the daemon's, else the one typed.
  if reply.core.len > 0: return reply.core
  if cmd.core.len > 0: return cmd.core
  corePart(cmd.unit)

proc formatError*(code: CoreErrorCode; message: string; core = ""): CliOutput =
  result = CliOutput(stderr: line(diagnostic(code, message, core)), exitStatus: exitCode(code))
proc formatError*(error: CoreError): CliOutput = formatError(error.code, error.msg, error.core)

proc formatWarnings*(warnings: seq[string]): string =
  for warning in warnings: result.add line("jumpctl: warning: " & oneLine(warning))

proc formatReply*(cmd: CliCommand; reply: Reply; collector = ReplyCollector()): CliOutput =
  ## Render the response of a single-request command. Success output is
  ## produced only for an `ok` response (§21.2).
  if not reply.ok:
    return formatError(reply.code, reply.message, cmd.diagnosticCore(reply))
  let value = collector.merged(reply)
  let owner = if reply.core.len > 0: reply.core else: corePart(cmd.unit)
  try:
    if cmd.kind == ccUnitsValidate:
      result = formatValidate(value, owner)
    else:
      result.stdout = formatSuccess(cmd, value, owner)
  except CoreError as e:
    return formatError(e.code, e.msg, if e.core.len > 0: e.core else: owner)
  result.stderr = formatWarnings(reply.warnings)

proc formatResponse*(cmd: CliCommand; response: ControlResponse; core = ""): CliOutput =
  ## Compatibility form taking a parsed `control` response.
  case response.status
  of rsOk:
    formatReply(cmd, Reply(ok: true, result: response.result,
      warnings: response.warnings, core: core))
  of rsError:
    formatReply(cmd, Reply(ok: false, code: response.error.code,
      message: response.error.message, core: core))

proc renderRunResult*(value: JsonNode): string =
  ## §21.15 for `core.verify` results (`installed`, `version`).
  formatRunResult("core.verify", value)

proc convertArgument*(operation, key, text: string): JsonNode =
  ## `cores run` arguments (§21.15): KEY=VALUE converted to the registry
  ## type of the argument (§16.3 conversions). Unknown keys are E_USAGE.
  let spec = findOperation(CurrentManifestVersion, operation)
  if spec.isNone: usage("unknown operation: " & operation)
  for field in spec.get.arguments:
    if field.name != key: continue
    case field.kind
    of vkString: return %text
    of vkBool:
      if text notin ["true", "false"]: usage(key & " must be true or false")
      return %(text == "true")
    of vkInt:
      var digits = text
      if digits.startsWith("-"): digits = digits[1 .. ^1]
      if digits.len == 0 or not digits.allCharsInSet({'0'..'9'}):
        usage(key & " must be an integer")
      try: return %parseBiggestInt(text)
      except ValueError: usage(key & " must be an integer")
    else: usage(key & " cannot be given on the command line")
  usage("unknown argument for " & operation & ": " & key)

# ---------------------------------------------------------------------------
# `cores run` (§21.15): any operation of one core, without the daemon.

type
  UnitUse* = enum
    ## How an operation takes its unit (§12 routing column).
    uuNone      ## `core` and `global` operations: UNIT is forbidden
    uuRequired  ## `unit` operations: UNIT is required
    uuOptional  ## `log.*`: unit-or-global; UNIT is optional

  RunRequest* = object
    core*, operation*, unit*: string
    args*: JsonNode
    known*: bool   ## the operation is in the registry; otherwise nothing else is parsed

proc unitUse*(operation: string): UnitUse =
  let spec = findOperation(CurrentManifestVersion, operation)
  if spec.isNone: return uuNone
  case spec.get.routing
  of orCore, orGlobal: uuNone
  of orUnit: uuRequired
  of orUnitOrGlobal: uuOptional

proc parseRunArguments*(args: seq[string]): RunRequest =
  ## `CORE OPERATION [UNIT] [KEY=VALUE...]` (§21.15). The argument after
  ## OPERATION is the UNIT when it contains no `=`; otherwise it is the first
  ## KEY=VALUE. UNIT is required for `unit` operations, optional for `log.*`,
  ## and an error for every other operation. It is kept exactly as typed: a
  ## core-local name, never qualified and never resolved.
  if args.len < 2: usage("expected CORE OPERATION [UNIT] [KEY=VALUE...]")
  result.core = args[0]
  result.operation = args[1]
  result.args = newJObject()
  if result.core.len == 0 or '/' in result.core:
    usage("CORE must be a core name: " & result.core)
  if not validOperationName(result.operation):
    usage("invalid operation name: " & result.operation)
  result.known = findOperation(CurrentManifestVersion, result.operation).isSome
  if not result.known: return
  var rest = args[2 .. ^1]
  let hasUnit = rest.len > 0 and '=' notin rest[0]
  case unitUse(result.operation)
  of uuNone:
    if hasUnit: usage(result.operation & " takes no UNIT: " & rest[0])
  of uuRequired:
    if not hasUnit: usage(result.operation & " requires a UNIT (a name without '=')")
  of uuOptional: discard
  if hasUnit:
    result.unit = rest[0]
    if '/' in result.unit:
      usage("UNIT must be a core-local name, not CORE/UNIT: " & result.unit)
    if not validUnitName(result.unit): usage("invalid unit name: " & result.unit)
    rest = rest[1 .. ^1]
  for assignment in rest:
    let (key, text) = splitAssignment(assignment)
    if result.args.hasKey(key): usage("duplicate argument: " & key)
    result.args[key] = convertArgument(result.operation, key, text)

proc mutatingWarning*(operation: string): string =
  ## The §21.15 warning line for a mutating operation.
  "jumpctl: warning: running " & operation & " outside the daemon: no locking, " &
    "supervision or daemon state; for debugging only\n"

proc runWarning*(operation: string): string =
  ## `mutatingWarning` when the registry class of `operation` is mutating
  ## (§11.6), "" for read-only, streaming and unknown operations.
  let spec = findOperation(CurrentManifestVersion, operation)
  if spec.isSome and spec.get.operationClass == ocMutating: mutatingWarning(operation)
  else: ""

proc formatLocalItem*(field: string; item: JsonNode): string =
  ## One streamed `item` or `entry` event of `cores run` (§21.15), with the
  ## line format of the matching normal command where there is one:
  ## `units` as `NAME SUBSYSTEM ENABLEMENT` (§21.4, without `CORE/`),
  ## `entries` as `TIME LEVEL UNIT MESSAGE` (§21.5), anything else as
  ## `FIELD: ` followed by the core object (`formatCoreObject`).
  case field
  of "units":
    if item.kind != JObject: reject("", "units must contain objects")
    for key in ["name", "subsystem", "enablement"]:
      if not item.hasKey(key): reject("", "units item missing " & key)
    oneLine(item["name"].getStr) & " " & oneLine(item["subsystem"].getStr) & " " &
      oneLine(item["enablement"].getStr) & "\n"
  of "entries": formatLogEntry(item)
  else:
    field & ": " & (if item.kind == JObject: formatCoreObject(item) else: oneLine(scalar(item))) & "\n"

proc formatLocalResult*(operation: string; value: JsonNode;
                        streamed: Table[string, int] = initTable[string, int]()): string =
  ## Result of `cores run` (§21.15): scalar fields as `KEY: VALUE` in registry
  ## order, list-of-objects fields one line per element (`formatLocalItem`),
  ## skipping the first `streamed[field]` elements that were already printed
  ## as they arrived. For `core.verify` this equals `formatRunResult`.
  let spec = findOperation(CurrentManifestVersion, operation)
  if spec.isNone or value.isNil or value.kind != JObject: return ""
  for field in spec.get.results:
    if not value.hasKey(field.name): continue
    let node = value[field.name]
    if field.kind == vkObjectList and node.kind == JArray:
      var skip = streamed.getOrDefault(field.name)
      for item in node:
        if skip > 0:
          dec skip
          continue
        result.add formatLocalItem(field.name, item)
    else:
      result.add formatRunResult(operation, %*{field.name: node})
