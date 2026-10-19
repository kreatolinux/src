## Pure supervisor lifecycle and exec-protocol notification model (§§15.2, 17).
##
## This module deliberately does not own a Process, file descriptor, timer, or
## signal.  The daemon feeds it lines, clock values, and exit observations and
## executes the actions returned by `beginUnload`/`continueUnload`.
import std/[algorithm, json, options, sets, strutils, tables, unicode]
import ../lifecycle/resources, ../manifest/types
import jumpstartcore/names

const
  ExecProtocol* = "jumpstart-core/1"
  MaxExecLineBytes* = 1024 * 1024
  SupervisorStopGraceMs* = 10_000'i64
  MaxNotificationDetailBytes* = 512

type
  SupervisorProtocolError* = object of ValueError
  SupervisorPhase* = enum
    spHandshaking, spRunning, spStopping, spExited
  ReportedUnitState* = enum
    rusActive, rusInactive, rusActivating, rusDeactivating, rusReloading, rusFailed,
    rusUnknown
  KnownUnitState* = object
    state*: ReportedUnitState
    detail*: string
    updatedAtMs*: int64
  NotificationDisposition* = enum
    ndRecorded, ndRateLimited, ndFilesystemsReady
  SupervisorAction* = enum
    saCloseDescriptor3, saSendTerm, saSendKill
  SupervisorModel* = object
    core*: string
    phase*: SupervisorPhase
    handshakeDeadlineMs*: int64
    stopDeadlineMs*: int64
    killIssued*: bool
    notifications*: NotificationWindow
    knownUnits: Table[string, KnownUnitState]
  SupervisorExitTransition* = enum
    setUnchanged, setDegraded, setLoadFailed

proc protocol(message: string) {.noreturn.} =
  raise newException(SupervisorProtocolError, message)

proc checkedDeadline(nowMs, delayMs: int64): int64 =
  if delayMs <= 0: raise newException(ValueError, "timeout must be positive")
  if nowMs > high(int64) - delayMs:
    raise newException(ValueError, "deadline overflow")
  nowMs + delayMs

proc initSupervisor*(core: string; startedAtMs, readyTimeoutMs: int64): SupervisorModel =
  if not validCoreName(core, extension = false):
    raise newException(ValueError, "invalid core name")
  result.core = core
  result.phase = spHandshaking
  result.handshakeDeadlineMs = checkedDeadline(startedAtMs, readyTimeoutMs)
  result.knownUnits = initTable[string, KnownUnitState]()

proc handshakeExpired*(model: SupervisorModel; nowMs: int64): bool =
  model.phase == spHandshaking and nowMs >= model.handshakeDeadlineMs

proc helloLine*(model: SupervisorModel; mode, jumpstartVersion: string): string =
  if mode notin ["system", "user"]: raise newException(ValueError, "invalid mode")
  $(%* {"type": "hello", "protocols": [ExecProtocol], "role": "supervisor",
        "core": model.core, "mode": mode, "jumpstart": jumpstartVersion}) & "\n"

proc parseObjectLine(line: string): JsonNode =
  var payload = line
  if payload.endsWith("\n"): payload.setLen(payload.len - 1)
  if payload.endsWith("\r"): payload.setLen(payload.len - 1)
  if payload.len > MaxExecLineBytes: protocol("exec protocol line exceeds 1 MiB")
  if payload.len == 0 or '\n' in payload or '\r' in payload:
    protocol("expected one complete non-empty line")
  try: result = parseJson(payload)
  except JsonParsingError as exc: protocol("malformed JSON: " & exc.msg)
  if result.kind != JObject: protocol("message must be an object")

proc rejectUnknown(node: JsonNode; allowed: openArray[string]) =
  var fields = initHashSet[string]()
  for field in allowed: fields.incl field
  for field, _ in node:
    if field notin fields: protocol("unknown field: " & field)

proc stringField(node: JsonNode; field: string): string =
  if not node.hasKey(field) or node[field].kind != JString:
    protocol(field & " must be a string")
  node[field].getStr

proc acceptHandshake*(model: var SupervisorModel; line: string; nowMs: int64) =
  ## A reply at the deadline is late: deadlines are exclusive completion
  ## bounds, matching operation timeout handling.
  if model.phase != spHandshaking: protocol("unexpected supervisor hello")
  if nowMs >= model.handshakeDeadlineMs: protocol("supervisor handshake timed out")
  let node = parseObjectLine(line)
  rejectUnknown(node, ["type", "protocol", "role"])
  if stringField(node, "type") != "hello": protocol("expected hello")
  if stringField(node, "protocol") != ExecProtocol: protocol("unsupported protocol")
  if stringField(node, "role") != "supervisor": protocol("hello role mismatch")
  model.phase = spRunning

proc parseReportedState(value: string): ReportedUnitState =
  case value
  of "active": rusActive
  of "inactive": rusInactive
  of "activating": rusActivating
  of "deactivating": rusDeactivating
  of "reloading": rusReloading
  of "failed": rusFailed
  of "unknown": rusUnknown
  else: protocol("invalid unit state")

proc receiveNotification*(model: var SupervisorModel; line: string;
                          nowMs: int64): NotificationDisposition =
  ## Rate limiting is per supervisor process/model. Dropped messages are not
  ## allowed to replace the durable last-known value.
  if model.phase notin {spRunning, spStopping}:
    protocol("notification before handshake or after exit")
  let node = parseObjectLine(line)
  if node.hasKey("type") and node["type"].kind == JString and
      node["type"].getStr == "filesystems-ready":
    # §17.5: no id and no reply; the daemon decides whether it still matters.
    rejectUnknown(node, ["type"])
    return ndFilesystemsReady
  rejectUnknown(node, ["type", "unit", "state", "detail"])
  if stringField(node, "type") != "notify": protocol("expected notify")
  let unit = stringField(node, "unit")
  if not validUnitName(unit): protocol("invalid unit name")
  let state = parseReportedState(stringField(node, "state"))
  var detail = ""
  if node.hasKey("detail"):
    if node["detail"].kind != JString: protocol("detail must be a string")
    detail = node["detail"].getStr
    if detail.len > MaxNotificationDetailBytes or detail.validateUtf8 != -1:
      protocol("detail must be valid UTF-8 and at most 512 bytes")
  if state == rusUnknown and detail.len == 0:
    protocol("unknown state requires detail")
  if not model.notifications.allowNotification(nowMs): return ndRateLimited
  model.knownUnits[unit] = KnownUnitState(state: state, detail: detail,
                                          updatedAtMs: nowMs)
  ndRecorded

proc lastKnown*(model: SupervisorModel; unit: string): Option[KnownUnitState] =
  if model.knownUnits.hasKey(unit): some(model.knownUnits[unit])
  else: none(KnownUnitState)

proc lastKnownUnits*(model: SupervisorModel): seq[string] =
  ## Table order is intentionally hidden so callers receive deterministic data.
  for unit in model.knownUnits.keys: result.add unit
  result.sort(system.cmp[string])

proc notificationDrops*(model: SupervisorModel): uint64 = model.notifications.dropped

proc observeExit*(model: var SupervisorModel; core: var CoreRuntime;
                  reason = "supervisor exited"): SupervisorExitTransition =
  ## No restart is planned: a replacement could not own existing descendants.
  let previous = model.phase
  model.phase = spExited
  if core.state == csLoaded and previous != spStopping:
    core.state = csDegraded
    core.failure = reason
    setDegraded
  elif core.state == csLoading:
    core.state = csFailed
    core.failure = reason
    setLoadFailed
  else:
    setUnchanged

proc beginUnload*(model: var SupervisorModel; nowMs: int64): seq[SupervisorAction] =
  ## The caller performs these in order after the core's shutdown operation.
  if model.phase == spExited: return
  if model.phase == spStopping: return
  model.phase = spStopping
  model.stopDeadlineMs = checkedDeadline(nowMs, SupervisorStopGraceMs)
  result = @[saCloseDescriptor3, saSendTerm]

proc continueUnload*(model: var SupervisorModel; nowMs: int64): seq[SupervisorAction] =
  ## An exit observation should be supplied before this call. SIGKILL is
  ## emitted exactly once if the process is still present when grace expires.
  if model.phase == spStopping and not model.killIssued and
      nowMs >= model.stopDeadlineMs:
    model.killIssued = true
    result.add saSendKill
