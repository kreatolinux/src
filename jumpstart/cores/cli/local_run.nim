## Running one operation of one core without the daemon (§21.15,
## `jumpctl cores run`).
##
## This is a debugging aid. It reuses the daemon's backend layer unchanged
## (`backend_runtime`, `adapter_runtime`, `spawn`): the same process
## specifications, descriptors, environment, sandbox, timeout and
## cancellation. What it deliberately does not have is everything that makes a
## daemon a daemon: no per-unit locking across requests, no admission limits,
## no `unit.resolve` routing, no shared adapters, no core log, no state.
##
## The module resolves the operation's backend (following `delegate` entries
## with the §13.4 rules), builds a private runtime that registers only the
## executing core, submits one request and drives the runtime until it
## completes, printing `item` and `entry` events through callbacks as they
## arrive. Afterwards it closes the adapter (§17.6) and waits for it to end.
import std/[json, options, os, sets, strutils, tables]
import posix
import ../backends/[adapter_runtime, backend_runtime], ../manifest/[manifest, modes]
import jumpstartcore/[errors, names, protocol, registry, registry_types, spawn]
from ../lifecycle/dispatch import MaxDelegationHops
from jumpstartcore/environment import modeName
from jumpstartcore/reaper import newReaper

const
  ServiceHandlerName* = "serviceHandler"
  NativeUnsupported* = "native operations need the daemon: use the normal jumpctl commands"
    ## E_UNSUPPORTED text for `native` entries (§13.6).

type
  LocalCore* = object
    ## A discovered, valid core: its manifest and directories.
    manifest*: CoreManifest
    dirs*: CoreDirectories

  CoreLoader* = proc(name: string): LocalCore {.closure.}
    ## Raises `CoreError` (`E_NOT_FOUND`, `E_MANIFEST`, ...) when the core is
    ## not discovered or not valid. Need not check the enabled set.

  LocalTarget* = object
    ## The operation that really runs, after following `delegate` entries.
    core*, operation*: string
    local*: LocalCore
    op*: ResolvedOp
    hops*: int                  ## delegations followed (0 = none)
    mutating*: bool             ## the typed or the final operation is mutating (§11.6)

  LocalRunHooks* = object
    ## Every hook is optional.
    onItem*: proc(operation, field: string; item: JsonNode) {.closure.}
      ## An `item` event for a list-of-objects field, validated (§17.4).
    onEntry*: proc(entry: JsonNode) {.closure.}
      ## An `entry` event of `log.follow`/`log.read`, validated (§17.4).
    onOutput*: proc(core, text: string) {.closure.}
      ## A line of the process's standard output or error, or a Kongue `log`.
    interrupted*: proc(): bool {.closure.}
      ## Polled between I/O passes; true cancels the request (§13.7).

  LocalRunOutcome* = object
    value*: JsonNode
    streamed*: Table[string, int]  ## `item` events printed per field
    core*, operation*: string

proc localFail(code: CoreErrorCode; message: string; core = "") {.noreturn.} =
  raise newCoreError(code, message, core)

proc operationClass(name: string): Option[OperationClass] =
  let spec = findOperation(CurrentManifestVersion, name)
  if spec.isSome: some(spec.get.operationClass) else: none(OperationClass)

proc isMutating*(operation: string): bool =
  ## Registry class `mutating` (§11.6, §12); false for unknown operations.
  let cls = operationClass(operation)
  cls.isSome and cls.get == ocMutating

proc operationIsStreaming*(operation: string): bool =
  ## Registry class `streaming` (`log.follow`, §11.6).
  let cls = operationClass(operation)
  cls.isSome and cls.get == ocStreaming

proc resolveTarget*(load: CoreLoader; mode: CoreMode; core, operation: string): LocalTarget =
  ## Resolve the executable backend of `operation` on `core`.
  ##
  ## * `unsupported` and absent entries are `E_UNSUPPORTED`; `native` entries
  ##   and `serviceHandler` are `E_UNSUPPORTED` with `NativeUnsupported`;
  ## * `delegate` entries are followed with the §13.4 rules: the cycle check,
  ##   at most four hops, and, past the first hop, `E_DELEGATION` for a target
  ##   that is unavailable or does not support the operation. Unlike the
  ##   daemon the target need not be enabled or loaded.
  var seen = initHashSet[string]()
  var current = core
  var currentOp = operation
  var hops = 0
  let typedMutating = isMutating(operation)
  while true:
    let key = current & "\x00" & currentOp
    if key in seen: localFail(ecDelegation, "delegation cycle", current)
    seen.incl key
    if current == ServiceHandlerName:
      if operationSubsystem(currentOp) == "core":
        localFail(ecUnsupported, "serviceHandler does not claim core", current)
      localFail(ecUnsupported, NativeUnsupported, current)
    var local: LocalCore
    try:
      local = load(current)
    except CoreError as e:
      if hops == 0: raise
      localFail(ecDelegation, "core is unavailable: " & current & ": " & e.msg, current)
    if mode notin local.manifest.modes:
      localFail(if hops == 0: ecUnsupported else: ecDelegation,
        "core does not support " & modeName(mode) & " mode", current)
    var selected = none(ResolvedOp)
    for op in local.manifest.resolveOps(mode):
      if op.name == currentOp: selected = some(op)
    if selected.isNone or selected.get.backend == manifest.bkUnsupported:
      localFail(if hops == 0: ecUnsupported else: ecDelegation,
        "operation is not supported: " & currentOp, current)
    let op = selected.get
    case op.backend
    of manifest.bkNative:
      localFail(ecUnsupported, NativeUnsupported, current)
    of manifest.bkDelegate:
      inc hops
      if hops > MaxDelegationHops:
        localFail(ecDelegation, "delegation chain exceeds four hops", current)
      current = op.delegateCore
      currentOp = op.delegateOperation
    else:
      return LocalTarget(core: current, operation: currentOp, local: local, op: op,
        hops: hops, mutating: typedMutating or isMutating(currentOp))

proc isObjectList(operation, field: string): bool =
  let spec = resultField(CurrentManifestVersion, operation, field)
  spec.isSome and spec.get.kind == vkObjectList

proc streamsEntries(operation: string): bool =
  ## Mirrors `adapter_runtime`: `entry` events belong to streaming operations
  ## and `log.read` (§17.4).
  let cls = operationClass(operation)
  cls.isSome and (cls.get == ocStreaming or operation == "log.read")

proc handle(event: RuntimeEvent; id: string; target: LocalTarget;
            hooks: LocalRunHooks; streamed: var Table[string, int]) =
  case event.kind
  of rekAdapter:
    let action = event.action
    if action.kind != aaEvent or action.requestId != id: return
    # A runner's `entry` is a core log line (it also arrives as `rekLog`).
    if event.adapter.startsWith(RuntimeRunnerName): return
    let message = action.message
    try:
      if message.kind == pmEventItem:
        if isObjectList(target.operation, message.field) and message.data.kind == JObject:
          validateObjectItem(target.operation, message.field, message.data)
          if not hooks.onItem.isNil: hooks.onItem(target.operation, message.field, message.data)
          streamed[message.field] = streamed.getOrDefault(message.field) + 1
      elif message.kind == pmEventEntry and streamsEntries(target.operation):
        validateEntry(message.data)
        if not hooks.onEntry.isNil: hooks.onEntry(message.data)
    except ProtocolError:
      discard  # the runtime fails the request with E_PROTOCOL
  of rekStdout, rekStderr, rekIoError, rekLog:
    if event.text.len > 0 and not hooks.onOutput.isNil:
      hooks.onOutput(target.core, event.text)
  of rekExit: discard

proc drain(driver: AdapterRuntime; id: string; target: LocalTarget;
           hooks: LocalRunHooks; streamed: var Table[string, int]) =
  while driver.hasEvents:
    handle(driver.nextEvent(), id, target, hooks, streamed)

proc runTarget*(config: RuntimeConfig; target: LocalTarget; unit: string; args: JsonNode;
                hooks = LocalRunHooks()): LocalRunOutcome =
  ## Run the resolved operation once, through a runtime private to this call.
  ## Persistent adapters are started by the request itself (handshake with the
  ## declared operation set, §17.2) and closed afterwards (§17.6), so nothing
  ## outlives the call except processes the core detached on purpose.
  let driver = initAdapterRuntime(modeName(config.mode), config.jumpstartVersion, newReaper())
  let runtime = newBackendRuntime(config, driver)
  runtime.registerManifest(target.local.manifest, target.local.dirs, "")
  result.core = target.core
  result.operation = target.operation
  result.streamed = initTable[string, int]()
  var streamed = initTable[string, int]()
  var completion: Completion
  var failure: ref CoreError
  try:
    let id = runtime.dispatch(target.core, target.operation, unit, args, monotonicMs())
    var cancelled = false
    while true:
      let now = monotonicMs()
      driver.pump(now)
      driver.advance(now)
      driver.drain(id, target, hooks, streamed)
      let done = driver.takeCompletion(id)
      if done.isSome:
        completion = done.get
        break
      if not driver.isPending(id):
        localFail(ecBackend, "request ended without a response", target.core)
      if not cancelled and not hooks.interrupted.isNil and hooks.interrupted():
        cancelled = true
        runtime.cancel(id, now)
      driver.waitSlice()
  except CoreError as e:
    failure = e
  runtime.unloadCore(target.core, monotonicMs())
  driver.waitIdle()
  driver.drain("", target, hooks, streamed)
  if not failure.isNil: raise failure
  result.streamed = streamed
  result.value = raiseOnFailure(completion, target.core)

type
  TransientRuntimeDir* = object
    ## The core's runtime directory (§19.1) when `cores run` had to create it.
    path: string
    created: bool
    device: Dev
    inode: Ino

proc ensureRuntimeDir*(path: string; mode: CoreMode; account: string): TransientRuntimeDir =
  ## The daemon creates `/run/jumpstart/cores/CORE` on load and removes it on
  ## unload (§19.1, §20.3 step 5), and an adapter may rely on it. Without a
  ## daemon `cores run` provides it for the duration of the command, as a
  ## private (`0700`) directory owned by `account` (user mode: the user). An
  ## existing directory belongs to a loaded core's daemon: it is used as it is
  ## and never changed, cleared, or removed. The state directory is never
  ## created (§19.1: cores tolerate its absence). Failing to create the
  ## directory is not an error; the operation then runs without it.
  result.path = path
  var st: Stat
  if lstat(path.cstring, st) == 0: return
  try:
    createDir(parentDir(path))
    if posix.mkdir(path.cstring, Mode(0o700)) != 0: return
    discard posix.chmod(path.cstring, Mode(0o700))
    if mode == cmSystem and account.len > 0:
      let identity = resolveIdentity(account)
      discard posix.lchown(path.cstring, identity.uid, identity.gid)
    if lstat(path.cstring, st) == 0 and S_ISDIR(st.st_mode):
      result.created = true
      result.device = st.st_dev
      result.inode = st.st_ino
  except CatchableError:
    discard

proc release*(dir: TransientRuntimeDir) =
  ## Remove a directory `ensureRuntimeDir` created, unless a daemon has since
  ## replaced it (a different inode), which is then left alone.
  if not dir.created: return
  var st: Stat
  if lstat(dir.path.cstring, st) != 0 or not S_ISDIR(st.st_mode) or
      st.st_dev != dir.device or st.st_ino != dir.inode: return
  try: removeDir(dir.path, checkDir = false)
  except CatchableError: discard

proc runLocal*(load: CoreLoader; config: RuntimeConfig; core, operation, unit: string;
               args: JsonNode; hooks = LocalRunHooks();
               beforeRun: proc(target: LocalTarget) {.closure.} = nil): LocalRunOutcome =
  ## Resolve, announce (`beforeRun`, e.g. the §21.15 warning), and run.
  let target = resolveTarget(load, config.mode, core, operation)
  if not beforeRun.isNil: beforeRun(target)
  let runtimeDir = ensureRuntimeDir(target.local.dirs.runtimeDir, config.mode,
    target.local.manifest.account)
  defer: runtimeDir.release()
  runTarget(config, target, unit, args, hooks)
