## Isolated Kongue core runner (jumpstart-cores §16).
##
## Jumpstart executes this program through a verified descriptor with the
## attributes of §15.4, completes the `runner` handshake on descriptors 3/4
## (§17.2) and sends one request carrying `function` (§17.3). The runner reads
## its core inputs from the `JUMPSTART_*` variables of §16.2, runs the Kongue
## function and writes every message to descriptor 4 as soon as it happens:
## `item` events for `respond-item`, `log` lines, `filesystems-ready`, then
## exactly one `response`.
##
## `log LEVEL MESSAGE` (§16.3) goes to the core's log (§19.2). §16.1 says the
## runner reports it over descriptor 4, and §17 defines no message of its own
## for it, so the runner sends an `entry` payload (`{time, level, unit,
## message}`, §12.10); for runner requests Jumpstart logs those entries with
## the request id and never adds them to the result.
##
## Programs are started with `jumpstartcore/spawn` (no osproc): `spawn` runs argv
## directly, without a shell (§16.4), and stays in the runner's process group
## so §13.7 cancellation reaches it. Standard output of the statement form and
## of `.exit()` is copied to the runner's standard output (logged at `info`),
## standard error always to the runner's standard error (logged at `warn`,
## §17.1). Only `init`/`shutdown` may use Kongue's `exec`, which runs
## `/bin/sh -c` through the same layer (§16.4).
import std/[json, options, os, sequtils, strutils, tables, times]
import posix
import ../kongue/kongue
import jumpstartcore/[errors, jsonlines, protocol, reaper, registry, registry_types,
  verified_file]
export jsonlines.readLineFd, jsonlines.writeAllFd
import jumpstartcore/spawn as corespawn

const
  RunnerOutputLimit* = 1024 * 1024
    ## §16.3: at most 1 MiB of a spawned program's standard output is
    ## captured. The same bound applies to `${exec(…)}` captures in
    ## `init`/`shutdown`, which §16 leaves unbounded.
  ShellPath* = "/bin/sh"
    ## §16.4: Kongue's `exec` runs its command through `/bin/sh -c`.
  LifecycleFunctions = ["init", "shutdown"]
    ## §16.2: `op` is absent in these and they may use `exec` (§16.4).

type
  RunnerFailure* = object of CatchableError
    code*: string
  SpawnResult* = object
    output*: string
    exitCode*: int
  RunnerInputs* = object
    ## §16.2 environment of a runner process.
    name*, root*, stateDir*, runtimeDir*, mode*: string
    operation*, unit*, requestId*: string ## absent for `init`/`shutdown`
  MessageSink* = proc(message: ProtocolMessage) {.closure.}
  SpawnForm = enum
    sfStatement, sfExit, sfOutput
  RunnerState* = ref object
    requestId*: string
    unit*: string
    function*: string
    result*: JsonNode
    items: OrderedTable[string, seq[JsonNode]]
    events*: seq[ProtocolMessage]     ## collected only when `sink` is nil
    sink*: MessageSink
    operation*: Option[OperationSpec]
    operationName*: string
    expressionSpawns*: seq[ManifestCall]
    expressionForms: seq[SpawnForm]
    handler*: bool
  RunnerContext* = ref object of ExecutionContext
    runner*: RunnerState

proc runnerFail(code, message: string) {.noreturn.} =
  var e = newException(RunnerFailure, message)
  e.code = code
  raise e

proc trimOneNewline*(value: string): string =
  ## Expression spawn removes exactly one trailing newline (CRLF counts as one).
  result = value
  if result.endsWith("\r\n"): result.setLen(result.len - 2)
  elif result.endsWith("\n"): result.setLen(result.len - 1)

proc protocolLine*(buffer: var string; chunk: string;
                   limit = MaxProtocolLineBytes): Option[string] =
  ## Feed bytes into a bounded newline framer (§17.1: at most 1 MiB per line).
  buffer.add chunk
  let nl = buffer.find('\n')
  if nl >= 0:
    if nl > limit: runnerFail("E_PROTOCOL", "protocol line exceeds 1 MiB")
    result = some(buffer[0 .. nl])
    buffer.delete(0 .. nl)
  elif buffer.len > limit:
    runnerFail("E_PROTOCOL", "protocol line exceeds 1 MiB")

proc validFailureCode*(code: string): bool = isErrorCodeName(code)

proc jsonString(value: JsonNode): string =
  ## §16.2: booleans and integers in `op.args` are rendered as strings.
  case value.kind
  of JString: value.getStr
  of JBool: $value.getBool
  of JInt: $value.getBiggestInt
  of JFloat: $value.getFloat
  of JNull: ""
  else: $value

# ---------------------------------------------------------------------------
# Inputs (§16.2)

proc readRunnerInputs*(function: string;
                       lookup: proc(name: string): string = nil): RunnerInputs =
  ## Read the §16.2 variables. Jumpstart always sets them, so a missing or
  ## relative value is a protocol violation of the parent (`E_PROTOCOL`).
  let get = if lookup.isNil: (proc(name: string): string = getEnv(name)) else: lookup
  proc required(name: string): string =
    result = get(name)
    if result.len == 0: runnerFail("E_PROTOCOL", "runner environment lacks " & name)
  proc absolute(name: string): string =
    result = required(name)
    if not result.isAbsolute: runnerFail("E_PROTOCOL", name & " is not absolute")
  result.name = required("JUMPSTART_CORE_NAME")
  result.root = absolute("JUMPSTART_CORE_ROOT")
  result.stateDir = absolute("JUMPSTART_CORE_STATE_DIR")
  result.runtimeDir = absolute("JUMPSTART_CORE_RUNTIME_DIR")
  result.mode = required("JUMPSTART_MODE")
  if result.mode notin ["system", "user"]:
    runnerFail("E_PROTOCOL", "JUMPSTART_MODE must be system or user")
  if function notin LifecycleFunctions:
    result.operation = required("JUMPSTART_OP")
    result.unit = get("JUMPSTART_UNIT")          # "" for core and global operations
    result.requestId = required("JUMPSTART_REQUEST_ID")

proc checkInputs(inputs: RunnerInputs; offer, request: ProtocolMessage) =
  ## The environment and the protocol describe the same core and request.
  if inputs.name != offer.core:
    runnerFail("E_PROTOCOL", "JUMPSTART_CORE_NAME does not match the hello core")
  if inputs.mode != offer.mode:
    runnerFail("E_PROTOCOL", "JUMPSTART_MODE does not match the hello mode")
  if request.function notin LifecycleFunctions:
    if inputs.operation != request.op or inputs.unit != request.unit or
        inputs.requestId != request.id:
      runnerFail("E_PROTOCOL", "JUMPSTART_OP, JUMPSTART_UNIT or JUMPSTART_REQUEST_ID " &
        "does not match the request")

# ---------------------------------------------------------------------------
# Messages and results (§16.3, §17.4)

proc send(state: RunnerState; message: ProtocolMessage) =
  if state.sink.isNil: state.events.add message
  else: state.sink(message)

proc fieldFor(state: RunnerState; name: string): Option[FieldSpec] =
  if state.operation.isNone: return none(FieldSpec)
  for field in state.operation.get.results:
    if field.name == name: return some(field)
  none(FieldSpec)

proc scalarValue*(kind: ValueKind; value: string): JsonNode =
  ## §16.3 conversion to the registry type of the field.
  case kind
  of vkString: %value
  of vkBool:
    case value
    of "true": %true
    of "false": %false
    else: runnerFail("E_PROTOCOL", "expected boolean result value: " & value)
  of vkInt:
    var digits = value
    if digits.startsWith("-"): digits = digits[1 .. ^1]
    if digits.len == 0 or not digits.allCharsInSet(Digits):
      runnerFail("E_PROTOCOL", "expected integer result value: " & value)
    try: %parseBiggestInt(value)
    except ValueError: runnerFail("E_PROTOCOL", "integer result value out of range: " & value)
  of vkStringList, vkIntList, vkObjectList:
    runnerFail("E_PROTOCOL", "result field requires a list command")

proc respond*(state: RunnerState; key, value: string) =
  let field = state.fieldFor(key)
  if state.operation.isSome and field.isNone:
    runnerFail("E_PROTOCOL", "unknown result field: " & key)
  if field.isNone:
    state.result[key] = %value # init/shutdown have no registry entry
    return
  case field.get.kind
  of vkStringList:
    if not state.result.hasKey(key): state.result[key] = newJArray()
    state.result[key].add(%value)
  of vkIntList:
    if not state.result.hasKey(key): state.result[key] = newJArray()
    state.result[key].add(scalarValue(vkInt, value))
  of vkObjectList:
    runnerFail("E_PROTOCOL", key & " requires respond-item")
  else:
    if state.result.hasKey(key): runnerFail("E_PROTOCOL", "result field set twice: " & key)
    state.result[key] = scalarValue(field.get.kind, value)

proc respondItem*(state: RunnerState; field: string; pairs: openArray[string]) =
  ## Append one object to a list-of-objects field and stream it as an `item`
  ## event (§17.4). Keys are checked against the §12 shape of the field; all
  ## §12 object fields are strings.
  let spec = state.fieldFor(field)
  if spec.isNone or spec.get.kind != vkObjectList:
    runnerFail("E_PROTOCOL", "unknown object-list result field: " & field)
  let keys = objectItemFields(state.operationName, field)
  var item = newJObject()
  for pair in pairs:
    let at = pair.find('=')
    if at <= 0: runnerFail("E_PROTOCOL", "respond-item expects KEY=VALUE")
    let key = pair[0 ..< at]
    if item.hasKey(key): runnerFail("E_PROTOCOL", "duplicate respond-item key: " & key)
    if keys.isSome and key notin keys.get:
      runnerFail("E_PROTOCOL", "unknown key for " & field & ": " & key)
    item[key] = %pair[at + 1 .. ^1]
  try: validateObjectItem(state.operationName, field, item)
  except ProtocolError as error: runnerFail("E_PROTOCOL", error.msg)
  state.items.mgetOrPut(field, @[]).add item
  state.send itemEvent(state.requestId, field, item)

proc logLine*(state: RunnerState; level, message: string) =
  ## §16.3 `log`: written to the core's log (§19.2) through descriptor 4.
  if level notin LogLevels: runnerFail("E_PROTOCOL", "unknown log level: " & level)
  state.send entryEvent(state.requestId, %*{"time": formatDeadline(getTime()),
    "level": level, "unit": state.unit, "message": message})

proc finishedResult(state: RunnerState): JsonNode =
  ## The result Jumpstart will see: streamed items first (§17.4).
  result = state.result.copy
  for field, items in state.items:
    var merged = newJArray()
    for item in items: merged.add item
    if result.hasKey(field):
      for item in result[field]: merged.add item
    result[field] = merged

proc validateFinished(state: RunnerState) =
  ## §16.3: Jumpstart validates the finished result against the registry; the
  ## runner checks first so a handler sees the same `E_PROTOCOL`.
  if state.operation.isNone: return
  try: validateResult(state.operationName, state.finishedResult)
  except ProtocolError as error: runnerFail("E_PROTOCOL", error.msg)

# ---------------------------------------------------------------------------
# Programs (§16.3 spawn, §16.4 exec)

var runnerReaper: Reaper

proc ensureReaper(): Reaper =
  if runnerReaper.isNil:
    runnerReaper = newReaper()
    installSigChldHandler(runnerReaper)
  runnerReaper

proc setNonBlocking(fd: cint) =
  let flags = fcntl(fd, F_GETFL, 0)
  if flags < 0 or fcntl(fd, F_SETFL, flags or O_NONBLOCK) < 0: raiseOSError(osLastError())

proc resolveProgram*(program, searchPath, workingDirectory: string): string =
  ## A program containing `/` is used as given (relative to the working
  ## directory); a bare name is looked up in `PATH`, as `execvp` would.
  if program.len == 0 or '\0' in program: runnerFail("E_BACKEND", "invalid spawn program")
  if '/' in program:
    return if program.isAbsolute: program else: workingDirectory / program
  for dir in searchPath.split(':'):
    if dir.len == 0 or not dir.isAbsolute: continue
    let candidate = dir / program
    if fileExists(candidate) and access(candidate.cstring, X_OK) == 0: return candidate
  runnerFail("E_BACKEND", "program not found in PATH: " & program)

proc runProgram(argv: seq[string]; workingDirectory: string;
                environment: seq[EnvPair]; capture: bool;
                limit = RunnerOutputLimit): SpawnResult =
  ## Run argv[0] with exactly argv[1..]. With `capture`, standard output is
  ## returned (bounded by `limit`, `E_BACKEND` beyond); otherwise it is copied
  ## to the runner's standard output. Standard error is always copied to the
  ## runner's standard error.
  let reaper = ensureReaper()
  var spec = ProcessSpec(executable: argv[0], arguments: argv[1 .. ^1],
    environment: environment, workingDirectory: workingDirectory,
    keepSession: true)
  var exited = false
  var status: ChildStatus
  var child: SpawnedProcess
  try:
    child = corespawn.spawn(spec, reaper, "kongue-runner",
      proc(s: ChildStatus) = exited = true; status = s)
  except CoreError as error:
    runnerFail("E_BACKEND", "spawn " & argv[0] & ": " & error.msg)
  except CatchableError as error:
    runnerFail("E_BACKEND", "spawn " & argv[0] & ": " & error.msg)
  var outOpen = true
  var errOpen = true
  var overflow = false
  var output = ""
  setNonBlocking(child.stdoutFd); setNonBlocking(child.stderrFd)
  var chunk = newString(65536)
  proc pull(fd: cint; open: var bool; isOut: bool) =
    while open:
      let n = posix.read(fd, addr chunk[0], chunk.len)
      if n > 0:
        if isOut and capture:
          if output.len + n > limit:
            overflow = true
            discard reaper.signalChild(child.pid, SIGKILL)
            closeFd(fd); open = false
            return
          output.add chunk[0 ..< n]
        else:
          writeAllFd(if isOut: STDOUT_FILENO else: STDERR_FILENO, chunk[0 ..< n])
      elif n == 0:
        closeFd(fd); open = false
      else:
        let err = osLastError()
        if err == OSErrorCode(EINTR): continue
        if err == OSErrorCode(EAGAIN) or err == OSErrorCode(EWOULDBLOCK): return
        closeFd(fd); open = false
  try:
    # The output form waits for end of file like command substitution; the
    # other forms end when the program exits, so a daemon it leaves behind
    # holding the pipes does not keep the handler running.
    while not (exited and (not capture or not outOpen)):
      var fds: seq[TPollfd]
      if outOpen: fds.add TPollfd(fd: child.stdoutFd, events: POLLIN)
      if errOpen: fds.add TPollfd(fd: child.stderrFd, events: POLLIN)
      fds.add TPollfd(fd: reaper.wakeupFd, events: POLLIN)
      let ready = poll(addr fds[0], Tnfds(fds.len), -1)
      if ready < 0:
        if osLastError() == OSErrorCode(EINTR): continue
        raiseOSError(osLastError())
      pull(child.stdoutFd, outOpen, true)
      pull(child.stderrFd, errOpen, false)
      discard reaper.drainWakeup()
    pull(child.stdoutFd, outOpen, true)
    pull(child.stderrFd, errOpen, false)
  finally:
    if outOpen: closeFd(child.stdoutFd)
    if errOpen: closeFd(child.stderrFd)
  if overflow: runnerFail("E_BACKEND", "spawn output exceeds 1 MiB")
  result.output = output
  result.exitCode = case status.kind
    of cekExited: status.code
    of cekSignaled: 128 + status.code     # shell convention for a signal end
    else: 1

proc environmentPairs(overrides: Table[string, string]): seq[EnvPair] =
  ## The runner's own (closed, §7.5) environment plus Kongue `env` changes.
  var merged = initOrderedTable[string, string]()
  for key, value in envPairs(): merged[key] = value
  for key, value in overrides: merged[key] = value
  for key, value in merged: result.add (key, value)

proc spawnArgv*(program: string; arguments: openArray[string];
                workingDirectory = ""; environment: seq[EnvPair] = @[];
                limit = RunnerOutputLimit; capture = true): SpawnResult =
  ## Execute argv directly. No argument is joined, quoted, or passed to a
  ## shell (§16.4). An empty environment means the runner's own.
  for arg in arguments:
    if '\0' in arg: runnerFail("E_BACKEND", "NUL in spawn argument")
  let cwd = if workingDirectory.len == 0: getCurrentDir() else: workingDirectory
  let env = if environment.len == 0: environmentPairs(initTable[string, string]())
            else: environment
  var searchPath = ""
  for (key, value) in env:
    if key == "PATH": searchPath = value
  let path = resolveProgram(program, searchPath, cwd)
  runProgram(@[path] & @arguments, cwd, env, capture, limit)

proc findExpressionToken(command: string): int =
  let marker = "__jumpstart_spawn_"
  let start = command.find(marker)
  if start < 0: return -1
  var stop = start + marker.len
  while stop < command.len and command[stop].isDigit: inc stop
  if stop == start + marker.len or not command[stop ..< min(command.len, stop + 2)].startsWith("__"):
    return -1
  try: parseInt(command[start + marker.len ..< stop])
  except ValueError: -1

proc executeSpawn(ctx: RunnerContext; argv: seq[string]; capture: bool): SpawnResult =
  ## `argv` was split from the source text (§16.4). Each element is
  ## interpolated on its own and never split, unquoted or re-parsed again.
  if argv.len == 0: runnerFail("E_BACKEND", "spawn requires PROGRAM")
  var resolved: seq[string]
  for value in argv: resolved.add(ctx.resolveVariables(value))
  spawnArgv(resolved[0], resolved[1 .. ^1], ctx.currentDir,
    environmentPairs(ctx.envVars), capture = capture)

proc runnerExecHook(ctx: ExecutionContext; command: string; silent: bool):
                    tuple[output: string; exitCode: int] =
  let runner = RunnerContext(ctx)
  let index = findExpressionToken(command)
  if index >= 0 and index < runner.runner.expressionSpawns.len:
    let form = runner.runner.expressionForms[index]
    let spawned = executeSpawn(runner, runner.runner.expressionSpawns[index].args,
      capture = form == sfOutput)
    if form == sfOutput: return (trimOneNewline(spawned.output), spawned.exitCode)
    return ("", spawned.exitCode)
  if runner.runner.handler:
    # §16.4: static validation rejects this; the runner refuses it as well.
    runnerFail("E_MANIFEST", "shell execution is forbidden in handlers")
  let ran = runProgram(@[ShellPath, "-c", command], ctx.currentDir,
    environmentPairs(initTable[string, string]()), capture = true)
  (ran.output.strip(leading = false, trailing = true, chars = {'\n'}), ran.exitCode)

proc runnerMacroHook(ctx: ExecutionContext; name: string; args: seq[string]): int =
  let runner = RunnerContext(ctx)
  if name == "spawn":
    let spawned = executeSpawn(runner, args, capture = false)
    if spawned.exitCode != 0:
      runnerFail("E_BACKEND", "spawn exited with status " & $spawned.exitCode)
    return 0
  var values: seq[string]
  for arg in args: values.add(ctx.resolveVariables(arg))
  case name
  of "respond":
    if values.len != 2: runnerFail("E_PROTOCOL", "respond expects KEY VALUE")
    runner.runner.respond(values[0], values[1])
  of "respond-item":
    if values.len < 2: runnerFail("E_PROTOCOL", "respond-item expects FIELD KEY=VALUE...")
    runner.runner.respondItem(values[0], values[1 .. ^1])
  of "fail":
    if values.len != 2: runnerFail("E_PROTOCOL", "fail expects CODE MESSAGE")
    # §16.3: E_BACKEND when CODE is not a defined code.
    runnerFail(errorName(kongueFailCode(values[0])), values[1])
  of "log":
    if values.len != 2: runnerFail("E_PROTOCOL", "log expects LEVEL MESSAGE")
    runner.runner.logLine(values[0], values[1])
  of "filesystems-ready":
    if values.len != 0: runnerFail("E_PROTOCOL", "filesystems-ready takes no arguments")
    if runner.runner.function == "shutdown":
      runnerFail("E_PROTOCOL", "filesystems-ready is allowed in handlers and init only")
    runner.runner.send(filesystemsReady())
  else:
    runnerFail("E_PROTOCOL", "unsupported macro: " & name)
  0

const RuntimeCommands = ["respond", "respond-item", "spawn", "fail", "log", "filesystems-ready"]

proc splitRuntimeArgs*(text: string): seq[string] =
  ## Split a runtime command's source text into arguments (§16.4: from the
  ## source text only, before any interpolation). A `${…}` interpolation is
  ## copied as it is, quotes included, even inside a quoted word.
  var current = ""
  var quote = '\0'
  var escaped = false
  var braces = 0
  var started = false
  var i = 0
  while i < text.len:
    let ch = text[i]
    if braces > 0:
      if ch == '{': inc braces
      elif ch == '}': dec braces
      current.add ch
    elif escaped:
      current.add(ch); escaped = false
    elif ch == '$' and i + 1 < text.len and text[i + 1] == '{':
      current.add "${"; braces = 1; started = true
      inc i
    elif ch == '\\' and quote != '\0':
      escaped = true
    elif quote != '\0':
      if ch == quote: quote = '\0'
      else: current.add(ch)
    elif ch in {'"', '\''}:
      quote = ch; started = true
    elif ch.isSpaceAscii:
      if current.len != 0 or started: result.add(current); current = ""
      started = false
    else:
      current.add(ch)
    inc i
  if quote != '\0' or braces != 0: runnerFail("E_MANIFEST", "malformed runtime command arguments")
  if current.len != 0 or started: result.add(current)

proc normalizeRuntimeNode(node: AstNode): AstNode =
  if node.kind == nkFuncCall and node.callName in RuntimeCommands:
    var args: seq[string]
    for expression in node.callArgs: args.add(splitRuntimeArgs(expression))
    return newMacroNode(node.callName, args, node.line)
  case node.kind
  of nkIf:
    node.thenBranch = node.thenBranch.mapIt(normalizeRuntimeNode(it))
    node.elseBranch = node.elseBranch.mapIt(normalizeRuntimeNode(it))
  of nkFor: node.forBody = node.forBody.mapIt(normalizeRuntimeNode(it))
  of nkBlock: node.blockBody = node.blockBody.mapIt(normalizeRuntimeNode(it))
  else: discard
  node

proc normalizeRuntimeCommands(parsed: var ParsedScript) =
  for fn in parsed.functions.mitems:
    if fn.kind == nkFunction: fn.funcBody = fn.funcBody.mapIt(normalizeRuntimeNode(it))
  for fn in parsed.customFuncs.mitems:
    if fn.kind == nkCustomFunc: fn.customFuncBody = fn.customFuncBody.mapIt(normalizeRuntimeNode(it))

proc prepareRuntimeSource*(source: string): string =
  ## Rewrite statement-leading §16.3 command words as Kongue macros; quoted
  ## expression forms are untouched.
  for line in source.splitLines(keepEol = true):
    let stripped = line.strip(leading = true, trailing = false)
    var runtime = false
    for command in RuntimeCommands:
      if stripped == command or stripped.startsWith(command & " "):
        runtime = true; break
    if runtime:
      let indent = line.len - stripped.len
      result.add(line[0 ..< indent] & "macro " & stripped)
    else:
      result.add(line)

proc spawnExpressionForms(source: string; calls: seq[ManifestCall]): seq[SpawnForm] =
  ## The method after each literal `${spawn(…)` (§16.3: `.exit()` or `.output()`).
  var searchFrom = 0
  for call in calls:
    if call.name != "spawn": continue
    let beginAt = source.find("${spawn(", searchFrom)
    if beginAt < 0: break
    var i = beginAt + 8
    var quoted = false
    var escaped = false
    while i < source.len:
      let ch = source[i]
      if escaped: escaped = false
      elif ch == '\\': escaped = true
      elif ch == '"': quoted = not quoted
      elif ch == ')' and not quoted: break
      inc i
    let rest = if i + 1 < source.len: source[i + 1 .. ^1] else: ""
    if rest.startsWith(".exit()"): result.add sfExit
    elif rest.startsWith(".output()"): result.add sfOutput
    else: runnerFail("E_MANIFEST", "spawn expression needs .exit() or .output()")
    searchFrom = i

proc rewriteSpawnExpressions*(source: string; calls: seq[ManifestCall]): string =
  ## Replace each literal spawn expression with a private exec-hook token.
  ## parseManifest has already validated/captured argv boundaries in `calls`.
  result = source
  var searchFrom = 0
  var spawnIndex = 0
  for call in calls:
    if call.name != "spawn": continue
    let beginAt = result.find("${spawn(", searchFrom)
    if beginAt < 0: break
    var i = beginAt + 8
    var quoted = false
    var escaped = false
    while i < result.len:
      let ch = result[i]
      if escaped: escaped = false
      elif ch == '\\': escaped = true
      elif ch == '"': quoted = not quoted
      elif ch == ')' and not quoted: break
      inc i
    if i >= result.len: break
    let replacement = "${exec(\"__jumpstart_spawn_" & $spawnIndex & "__\")"
    result = result[0 ..< beginAt] & replacement & result[i + 1 .. ^1]
    searchFrom = beginAt + replacement.len
    inc spawnIndex

proc headerString(header: HeaderValue; key: string): string =
  let value = header.getHeader(key)
  if value != nil and value.kind == hvString: value.stringVal else: ""

proc objectValue(pairs: openArray[(string, string)]): VarValue =
  var values = initTable[string, VarValue]()
  for (key, value) in pairs: values[key] = newStringValue(value)
  newObjectValue(values)

proc newRunnerContext*(parsed: ParsedScript; offer, request: ProtocolMessage;
                       inputs: RunnerInputs; sink: MessageSink = nil): RunnerContext =
  let base = initExecutionContext(srcDir = inputs.root)
  result = RunnerContext()
  result.variables = base.variables; result.listVariables = base.listVariables
  result.objectVariables = base.objectVariables; result.localVars = base.localVars
  result.envVars = base.envVars; result.customFuncs = base.customFuncs
  result.currentDir = base.currentDir; result.previousDir = base.previousDir
  result.destDir = base.destDir; result.srcDir = base.srcDir
  result.buildRoot = base.buildRoot; result.packageName = base.packageName
  result.maxCallDepth = base.maxCallDepth
  let handler = request.function notin LifecycleFunctions
  result.runner = RunnerState(requestId: request.id, unit: request.unit,
    function: request.function, result: newJObject(), sink: sink,
    items: initOrderedTable[string, seq[JsonNode]](),
    operation: if handler: findOperation(CurrentManifestVersion, request.op)
               else: none(OperationSpec),
    operationName: request.op, handler: handler)
  if handler and result.runner.operation.isNone:
    runnerFail("E_PROTOCOL", "unknown operation: " & request.op)
  result.execHook = runnerExecHook
  result.macroHook = runnerMacroHook
  result.loadAllFunctions(parsed)
  result.setObjectVariable("core", objectValue({
    "name": inputs.name, "core_version": headerString(parsed.manifestHeader, "core_version"),
    "version": headerString(parsed.manifestHeader, "version"), "root": inputs.root,
    "state_dir": inputs.stateDir, "runtime_dir": inputs.runtimeDir, "mode": inputs.mode,
    "jumpstart_version": offer.jumpstart}))
  if handler:
    var opValues = initTable[string, VarValue]()
    let subsystem = if '.' in request.op: request.op.split('.')[0] else: ""
    for (key, value) in {"name": request.op, "role": "handler", "unit": request.unit,
                         "subsystem": subsystem, "request_id": request.id,
                         "deadline": request.deadline}:
      opValues[key] = newStringValue(value)
    var args = initTable[string, VarValue]()
    for key, value in request.args: args[key] = newStringValue(jsonString(value))
    opValues["args"] = newObjectValue(args)
    result.setObjectVariable("op", newObjectValue(opValues))

proc newRunnerContext*(parsed: ParsedScript; offer, request: ProtocolMessage;
                       root: string): RunnerContext =
  ## Compatibility form: core inputs taken from the hello and `root`.
  newRunnerContext(parsed, offer, request, RunnerInputs(name: offer.core,
    root: root, mode: offer.mode, operation: request.op, unit: request.unit,
    requestId: request.id))

proc runRequest*(offer, request: ProtocolMessage; manifestSource: string;
                 inputs: RunnerInputs; sink: MessageSink = nil):
                 tuple[messages: seq[ProtocolMessage]; exitCode: int] =
  ## Run one request. With a `sink`, events are delivered as they happen and
  ## the final response is passed to it too; otherwise everything is returned.
  if offer.kind != pmHelloOffer or offer.role != crRunner:
    runnerFail("E_PROTOCOL", "runner expected a runner hello")
  if request.kind != pmRequest or request.function.len == 0:
    runnerFail("E_PROTOCOL", "runner request requires function")
  checkInputs(inputs, offer, request)
  let initial = parseManifest(manifestSource)
  let forms = spawnExpressionForms(manifestSource, initial.manifestCalls)
  let rewritten = rewriteSpawnExpressions(manifestSource, initial.manifestCalls)
  var parsed = parseManifest(rewritten)
  normalizeRuntimeCommands(parsed)
  let body = getFunctionByName(parsed, request.function)
  if body.len == 0: runnerFail("E_MANIFEST", "function not found: " & request.function)
  let ctx = newRunnerContext(parsed, offer, request, inputs, sink)
  for call in initial.manifestCalls:
    if call.name == "spawn": ctx.runner.expressionSpawns.add(call)
  ctx.runner.expressionForms = forms
  let status = ctx.executeFunction(body)
  if status != 0: runnerFail("E_BACKEND", "Kongue function exited with status " & $status)
  # A required list-of-objects field with no items is sent as `[]`; streamed
  # items are placed before it (§17.4).
  for field in (if ctx.runner.operation.isSome: ctx.runner.operation.get.results else: @[]):
    if field.kind == vkObjectList and not field.optional and
        not ctx.runner.result.hasKey(field.name):
      ctx.runner.result[field.name] = newJArray()
  validateFinished(ctx.runner)
  ctx.runner.send(okResponse(request.id, ctx.runner.result))
  result.messages = ctx.runner.events

proc runRequest*(offer, request: ProtocolMessage; manifestSource, root: string):
                 tuple[messages: seq[ProtocolMessage]; exitCode: int] =
  ## Compatibility form without the §16.2 environment.
  runRequest(offer, request, manifestSource, RunnerInputs(name: offer.core,
    root: root, mode: offer.mode, operation: request.op, unit: request.unit,
    requestId: request.id))

proc setCloexec(fd: cint) =
  if fcntl(fd, F_SETFD, FD_CLOEXEC) < 0: raiseOSError(osLastError())

proc runnerMain*(inputFd = 3.cint; outputFd = 4.cint): int =
  ## §15.4: descriptors 3 and 4 are made close-on-exec first, so programs the
  ## runner starts never inherit them.
  setCloexec(inputFd); setCloexec(outputFd)
  var requestId = ""
  var responded = false
  let sink: MessageSink = proc(message: ProtocolMessage) =
    if message.kind in {pmResponseOk, pmResponseError}: responded = true
    writeAllFd(outputFd, encodeLine(message))
  proc reportFailure(code, message: string) =
    if requestId.len != 0 and not responded:
      sink(errorResponse(requestId, code, message))
    else:
      stderr.writeLine("kongue-runner: " & code & ": " & message)
  try:
    let offer = parseLine(readLineFd(inputFd))
    validateHandshake(offer, helloReply(crRunner), [])
    writeAllFd(outputFd, encodeLine(helloReply(crRunner)))
    let request = parseLine(readLineFd(inputFd))
    requestId = request.id
    let inputs = readRunnerInputs(request.function)
    # §8.3: the manifest is re-opened with O_NOFOLLOW and re-checked with
    # fstat. The runner holds the core's account (§15.4), so besides root the
    # trusted owner is that account; in user mode this is the user.
    let manifestSource = readVerifiedFile(inputs.root / "init.kg", geteuid())
    discard runRequest(offer, request, manifestSource, inputs, sink)
    0
  except RunnerFailure as e:
    reportFailure(e.code, e.msg)
    1
  except CoreError as e:
    reportFailure(errorName(e.code), e.msg)
    1
  except CatchableError as e:
    reportFailure("E_BACKEND", e.msg)
    1

when isMainModule:
  quit(runnerMain())
