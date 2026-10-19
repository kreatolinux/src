## Executable backend planning and runner interfaces.
##
## The module owns no processes or file descriptors.  Privileged descriptor
## opening and process control are injected as callbacks, which keeps the
## policy and protocol state machine usable by both the daemon and pure tests.
import std/[json, options, strutils, tables, times]
import ../lifecycle/dispatch
import jumpstartcore/[errors, protocol]
from ../manifest/modes import kongueRunnerDefault

const
  PersistentHandshakeTimeoutMs* = 10_000'i64
    ## §17.2: persistent adapters reply to hello within 10 seconds.
  BackendTerminationGraceMs* = 5_000'i64
    ## §13.7: wait up to 5 seconds between SIGTERM/`cancel` and SIGKILL.
  DefaultKongueRunner* = kongueRunnerDefault
    ## §16.1, §25: the runner Jumpstart's package installs.

type
  BackendErrorCode* = enum
    beInvalidPlan, bePermission, beProtocol, beBackend, beTimeout, beCancelled,
    beResult

  BackendError* = object of CoreError
    ## A `CoreError` whose `code` is the §18 code reported to clients;
    ## `kind` says which backend stage failed.
    kind*: BackendErrorCode

  ExecutableDescriptor* = object
    ## An opaque proof supplied by the descriptor-opening layer after an
    ## O_NOFOLLOW open and fstat re-check.  `handle` is deliberately abstract:
    ## it may be an fd, capability index, or fake-test token.
    handle: int
    path: string
    regular, ownerExecutable, noFollow: bool

  InvocationKind* = enum
    ikOneshotAdapter, ikPersistentAdapter, ikCustomRunner

  SpawnModel* = object
    ## Spawn-layer-neutral process attributes required by §15.4.
    executable*: ExecutableDescriptor
    argv*: seq[string]
    environment*: Table[string, string]
    workingDirectory*, user*, controlGroup*: string
    newSession*, protocolDescriptors*, closeOtherDescriptors*: bool

  BackendRequest* = object
    id*, operation*, unit*, deadline*: string
    args*: JsonNode

  ExecutionPlan* = object
    kind*: InvocationKind
    core*, mode*, jumpstartVersion*: string
    routedOperations*: seq[string]
    timeoutMs*, handshakeTimeoutMs*, graceMs*: int64
    handler*: string
    spawn*: SpawnModel
    offer*, requestMessage*: ProtocolMessage

  ExecutorStatus* = enum
    esCompleted, esTimedOut, esCancelled, esProcessFailed

  ExecutorOutcome* = object
    ## Complete protocol lines in arrival order. A real executor may collect
    ## these incrementally; the runner applies the same validation afterwards.
    status*: ExecutorStatus
    lines*: seq[string]
    exitCode*: int
    exitedBeforeResponse*: bool

  EscalationKind* = enum
    ekTerminateProcessGroup, ekCancelRequest, ekKillProcessGroup,
    ekKillPersistentAdapter

  Escalation* = object
    kind*: EscalationKind
    requestId*: string
    message*: string                 ## encoded cancel line when applicable
    waitMs*: int64

  BackendResult* = object
    value*: JsonNode
    events*: seq[ProtocolMessage]

  DescriptorOpener* = proc(path: string): ExecutableDescriptor {.closure.}
  Executor* = proc(plan: ExecutionPlan): ExecutorOutcome {.closure.}
  Escalator* = proc(plan: ExecutionPlan; action: Escalation): bool {.closure.}
    ## Return true when the soft action stopped the process. Kill actions ignore
    ## the return value.
  ResultValidator* = proc(operation: string; value: JsonNode): bool {.closure.}

proc coreCodeFor*(kind: BackendErrorCode): CoreErrorCode =
  ## Default §18 code of each backend failure kind.
  case kind
  of beInvalidPlan: ecBackend
  of bePermission: ecPermission
  of beProtocol, beResult: ecProtocol
  of beBackend: ecBackend
  of beTimeout: ecTimeout
  of beCancelled: ecCancelled

proc backendFail(kind: BackendErrorCode; message: string;
                 code = coreCodeFor(kind)) {.noreturn.} =
  var error = newException(BackendError, message)
  error.kind = kind
  error.code = code
  error.message = message
  raise error

proc toCoreError*(error: ref BackendError): ref CoreError =
  newCoreError(error.code, error.msg, error.core)

proc verifiedExecutable*(handle: int; path: string; regular = true;
                         ownerExecutable = true; noFollow = true): ExecutableDescriptor =
  ## Constructor intended for an O_NOFOLLOW/fstat implementation and fakes.
  ExecutableDescriptor(handle: handle, path: path, regular: regular,
    ownerExecutable: ownerExecutable, noFollow: noFollow)

proc descriptorHandle*(descriptor: ExecutableDescriptor): int = descriptor.handle
proc descriptorPath*(descriptor: ExecutableDescriptor): string = descriptor.path

proc requireVerified*(descriptor: ExecutableDescriptor;
                      expectedPath = ""): ExecutableDescriptor =
  if descriptor.handle < 0 or descriptor.path.len == 0 or
      not descriptor.regular or not descriptor.ownerExecutable or
      not descriptor.noFollow:
    backendFail(bePermission, "executable descriptor failed verification")
  if expectedPath.len != 0 and descriptor.path != expectedPath:
    backendFail(bePermission, "opened executable does not match requested path")
  descriptor

proc executablePath*(coreDirectory, relativePath: string): string =
  ## Apply the exec-backend path policy without touching the filesystem.
  if coreDirectory.len == 0 or relativePath.len == 0 or
      relativePath.startsWith("/") or '\0' in relativePath:
    backendFail(beInvalidPlan, "executable must be relative to the core", ecLayout)
  let parts = relativePath.split('/')
  if parts.len < 2 or parts[0] != "bin":
    backendFail(beInvalidPlan, "executable must be below bin/", ecLayout)
  for part in parts:
    if part.len == 0 or part == "." or part == "..":
      backendFail(beInvalidPlan, "invalid executable path component", ecLayout)
  coreDirectory.strip(leading = false, trailing = true, chars = {'/'}) & "/" & relativePath

proc openCoreExecutable*(coreDirectory, relativePath: string;
                         opener: DescriptorOpener): ExecutableDescriptor =
  if opener.isNil: backendFail(beInvalidPlan, "descriptor opener is required")
  let path = executablePath(coreDirectory, relativePath)
  requireVerified(opener(path), path)

proc spawnModel(descriptor: ExecutableDescriptor; argv: seq[string];
                backend: ResolvedBackend; controlGroup: string): SpawnModel =
  result = SpawnModel(executable: requireVerified(descriptor), argv: argv,
    environment: backend.environment, workingDirectory: backend.workingDirectory,
    user: backend.user, controlGroup: controlGroup, newSession: true,
    protocolDescriptors: true, closeOtherDescriptors: true)
  if result.argv.len == 0: result.argv = @[descriptor.path]

proc wireDeadline*(deadline: string): string =
  ## Request `deadline` as RFC 3339 (§17.3). Callers that still pass Unix
  ## epoch seconds (a decimal number) are converted rather than sent as is.
  if validDeadline(deadline): return deadline
  try:
    let seconds = parseFloat(deadline)
    if seconds > 0: return formatDeadline(fromUnixFloat(seconds))
  except ValueError: discard
  backendFail(beInvalidPlan, "deadline must be an RFC 3339 timestamp")

proc requestFor(planKind: InvocationKind; request: BackendRequest;
                handler: string): ProtocolMessage =
  if request.args.isNil or request.args.kind != JObject:
    backendFail(beInvalidPlan, "backend request args must be an object")
  let deadline = wireDeadline(request.deadline)
  try:
    protocol.request(request.id, request.operation, request.unit, request.args,
      deadline, if planKind == ikCustomRunner: handler else: "")
  except ProtocolError as error:
    backendFail(beInvalidPlan, error.msg)

proc planExecInvocation*(operation: PlannedOperation; coreDirectory, mode,
                         jumpstartVersion, controlGroup: string;
                         routedOperations: seq[string]; request: BackendRequest;
                         opener: DescriptorOpener): ExecutionPlan =
  let backend = operation.backend
  if backend.kind != bkExec:
    backendFail(beInvalidPlan, "exec invocation requires an exec backend")
  let descriptor = openCoreExecutable(coreDirectory, backend.executable, opener)
  result.kind = if backend.execMode == emPersistent: ikPersistentAdapter
                else: ikOneshotAdapter
  result.core = operation.core
  result.mode = mode
  result.jumpstartVersion = jumpstartVersion
  result.routedOperations = routedOperations
  result.timeoutMs = backend.timeoutMs
  result.handshakeTimeoutMs = if result.kind == ikPersistentAdapter:
                                PersistentHandshakeTimeoutMs else: backend.timeoutMs
  result.graceMs = BackendTerminationGraceMs
  result.spawn = spawnModel(descriptor, @[descriptor.path] & backend.arguments,
    backend, controlGroup)
  try: result.offer = helloOffer(crAdapter, result.core, mode, jumpstartVersion)
  except ProtocolError as error: backendFail(beInvalidPlan, error.msg)
  result.requestMessage = requestFor(result.kind, request, "")

proc planCustomInvocation*(operation: PlannedOperation; runner: ExecutableDescriptor;
                           mode, jumpstartVersion, controlGroup: string;
                           request: BackendRequest): ExecutionPlan =
  let backend = operation.backend
  if backend.kind != bkCustom:
    backendFail(beInvalidPlan, "custom invocation requires a custom backend")
  result.kind = ikCustomRunner
  result.core = operation.core
  result.mode = mode
  result.jumpstartVersion = jumpstartVersion
  result.timeoutMs = backend.timeoutMs
  result.handshakeTimeoutMs = backend.timeoutMs
  result.graceMs = BackendTerminationGraceMs
  result.handler = backend.handler
  result.spawn = spawnModel(requireVerified(runner), @[runner.path], backend,
    controlGroup)
  try: result.offer = helloOffer(crRunner, result.core, mode, jumpstartVersion)
  except ProtocolError as error: backendFail(beInvalidPlan, error.msg)
  result.requestMessage = requestFor(result.kind, request, backend.handler)

proc planInvocation*(dispatchPlan: DispatchPlan; coreDirectory, mode,
                     jumpstartVersion, controlGroup: string;
                     routedOperations: seq[string]; request: BackendRequest;
                     opener: DescriptorOpener;
                     runner: Option[ExecutableDescriptor] = none(ExecutableDescriptor)): ExecutionPlan =
  ## Bridge a resolved delegation plan to the terminal executable backend.
  case dispatchPlan.target.backend.kind
  of bkExec:
    planExecInvocation(dispatchPlan.target, coreDirectory, mode, jumpstartVersion,
      controlGroup, routedOperations, request, opener)
  of bkCustom:
    if runner.isNone:
      backendFail(beInvalidPlan, "custom invocation requires a verified runner")
    planCustomInvocation(dispatchPlan.target, runner.get, mode, jumpstartVersion,
      controlGroup, request)
  else:
    backendFail(beInvalidPlan, "dispatch target is not an executable backend")

proc persistentKey*(plan: ExecutionPlan): string =
  if plan.kind != ikPersistentAdapter:
    backendFail(beInvalidPlan, "only persistent plans have a sharing key")
  plan.core & "\x00" & plan.spawn.executable.path

proc samePersistentProcess*(left, right: ExecutionPlan): bool =
  ## Options that the manifest requires to be identical for shared adapters.
  left.kind == ikPersistentAdapter and right.kind == ikPersistentAdapter and
    left.persistentKey == right.persistentKey and
    left.spawn.user == right.spawn.user and left.spawn.argv == right.spawn.argv and
    left.spawn.environment == right.spawn.environment and
    left.spawn.workingDirectory == right.spawn.workingDirectory

proc escalation(plan: ExecutionPlan; status: ExecutorStatus;
                executor: Escalator) =
  if executor.isNil: return
  let persistent = plan.kind == ikPersistentAdapter
  let soft = Escalation(
    kind: if persistent: ekCancelRequest else: ekTerminateProcessGroup,
    requestId: plan.requestMessage.id,
    message: if persistent: encodeLine(protocol.cancel(plan.requestMessage.id)) else: "",
    waitMs: plan.graceMs)
  if not executor(plan, soft):
    discard executor(plan, Escalation(
      kind: if persistent: ekKillPersistentAdapter else: ekKillProcessGroup,
      requestId: plan.requestMessage.id, waitMs: 0))

proc mergeItem(result: JsonNode; message: ProtocolMessage) =
  if result.kind != JObject:
    backendFail(beProtocol, "item event requires an object result")
  if not result.hasKey(message.field): result[message.field] = newJArray()
  if result[message.field].kind != JArray:
    backendFail(beProtocol, "item event field is not an array")
  # Events precede response values, so prepend without relying on JsonNode's
  # internal sequence representation.
  var combined = newJArray()
  combined.add message.data
  for item in result[message.field]: combined.add item
  result[message.field] = combined

proc runBackend*(plan: ExecutionPlan; executor: Executor;
                 escalator: Escalator = nil;
                 validateResult: ResultValidator = nil): BackendResult =
  ## Validate one completed exchange. Raises `BackendError`, a `CoreError`
  ## whose code is the §18 code: `E_TIMEOUT`/`E_CANCELLED` for expiry and
  ## cancellation, `E_PROTOCOL` for protocol and result-schema violations,
  ## the adapter's own code for an error response, `E_BACKEND` for a process
  ## that exited before responding. Without `validateResult` the result is
  ## validated against the registry (§16.3).
  if executor.isNil: backendFail(beInvalidPlan, "executor is required")
  let outcome = executor(plan)
  case outcome.status
  of esTimedOut:
    escalation(plan, outcome.status, escalator)
    backendFail(beTimeout, "backend operation timed out")
  of esCancelled:
    escalation(plan, outcome.status, escalator)
    backendFail(beCancelled, "backend operation was cancelled")
  of esProcessFailed:
    backendFail(beBackend, "backend process failed with status " & $outcome.exitCode)
  of esCompleted: discard

  if outcome.exitedBeforeResponse:
    backendFail(beBackend, "backend exited before responding")
  if outcome.lines.len < 2:
    backendFail(beProtocol, "backend omitted handshake or response")

  var messages: seq[ProtocolMessage]
  try:
    let reply = parseLine(outcome.lines[0])
    validateHandshake(plan.offer, reply, plan.routedOperations)
    for index in 1 ..< outcome.lines.len: messages.add parseLine(outcome.lines[index])
  except ProtocolError as error:
    backendFail(beProtocol, error.msg)

  var responseSeen = false
  var value: JsonNode
  var items: seq[ProtocolMessage]
  for message in messages:
    case message.kind
    of pmNotify, pmFilesystemsReady:
      discard                         # consumed by daemon-level hooks elsewhere
    of pmEventEntry, pmEventItem:
      if responseSeen or message.id != plan.requestMessage.id:
        backendFail(beProtocol, "event has unknown id or follows response")
      if message.kind == pmEventEntry:
        try: validateEntry(message.data)
        except ProtocolError as error: backendFail(beProtocol, error.msg)
      result.events.add message
      if message.kind == pmEventItem: items.add message
    of pmResponseOk, pmResponseError:
      if responseSeen or message.id != plan.requestMessage.id:
        backendFail(beProtocol, "duplicate response or unknown request id")
      responseSeen = true
      if message.kind == pmResponseError:
        # §17.3/§18: the adapter's or runner's code is the operation's code.
        let (code, detail) = responseFailure(message)
        backendFail(if code == ecProtocol: beProtocol else: beBackend, detail, code)
      value = message.result.copy
    else:
      backendFail(beProtocol, "unexpected protocol message from backend")
  if not responseSeen: backendFail(beProtocol, "backend omitted response")
  for index in countdown(items.high, 0): mergeItem(value, items[index])
  if validateResult.isNil:
    try: protocol.validateResult(plan.requestMessage.op, value)
    except ProtocolError as error: backendFail(beResult, error.msg)
  elif not validateResult(plan.requestMessage.op, value):
    backendFail(beResult, "backend result failed validation")
  result.value = value
