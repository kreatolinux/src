## Manifest-level orchestration of executable backends (§13.2, §13.3, §16,
## §17) on top of the real driver in `adapter_runtime`.
##
## For every request this module builds the complete process specification
## immediately before the spawn:
##
## * the executable is opened with `O_NOFOLLOW` beneath the core directory and
##   re-checked on the descriptor, then executed through it (§8.3, §24);
## * the environment is the closed four-layer environment of §7.5 with the
##   `JUMPSTART_*` variables of §16.2 (request variables only for runners and
##   oneshot adapters);
## * system mode switches to the `user` option's account (§13.1);
## * `sandbox: true` applies the §13.8 sandbox (failure is `E_SANDBOX`);
## * the process joins the core's `control/` cgroup (§15.1).
##
## Requests take the §11.6 locks, are bounded by the operation's `timeout`,
## and are cancelled per §13.7. Persistent adapters are shared per executable,
## started at load, multiplexed, and restarted lazily (§17.6).
import std/[json, options, os, tables]
import posix
import ./[adapter, adapter_runtime], ../lifecycle/dispatch, ../manifest/[manifest, modes]
import jumpstartcore/[environment, errors, protocol, registry, sandbox, spawn]
export adapter.AdapterState, adapter_runtime.Completion, adapter_runtime.RuntimeEvent,
  adapter_runtime.RuntimeEventKind

const RuntimeRunnerName* = "@kongue-runner"

type
  CoreDirectories* = object
    root*, stateDir*, runtimeDir*: string

  UserStoreSnapshot* = proc(): Environment {.closure.}

  RuntimeConfig* = object
    mode*: CoreMode
    jumpstartVersion*: string
    runnerPath*: string           ## Kongue runner, executed through a verified fd (§16.1)
    runnerTrustedUid*: Uid        ## owner the runner must have (root)
    trustedUid*: Uid              ## trusted owner of core files (§8.3)
    identity*: UserIdentity       ## user mode: password-database fields (§7.5)
    runtimeDir*: string           ## user mode: RUNTIME (§7.2)
    canonicalRuntimeDir*: bool    ## RUNTIME is /run/user/UID, so XDG_RUNTIME_DIR is set
    userStore*: UserStoreSnapshot ## user mode: current `jumpctl env` store
    forbiddenRoots*: seq[string]  ## §13.1: system-mode writable_paths exclusions

  Binding = object
    core: string
    op: ResolvedOp
    info: OperationSpec
    persistentName: string

  CoreEntry = object
    manifest: CoreManifest
    dirs: CoreDirectories
    cgroupProcs: string
    routed: Table[string, seq[string]]   # executable -> every op routed to it
    persistent: seq[string]

  BackendRuntime* = ref object
    config: RuntimeConfig
    driver*: AdapterRuntime
    cores: Table[string, CoreEntry]
    bindings: Table[string, Binding]
    nextRequest: uint64

proc runtimeFail(code: CoreErrorCode; message: string; core = "") {.noreturn.} =
  raise newCoreError(code, message, core)

proc bindingKey(core, operation: string): string = core & "\x00" & operation
proc persistentName(core, executable: string): string = core & "/" & executable

proc newBackendRuntime*(config: RuntimeConfig; driver: AdapterRuntime): BackendRuntime =
  if config.jumpstartVersion.len == 0: runtimeFail(ecUsage, "Jumpstart version is required")
  if driver.isNil: runtimeFail(ecUsage, "driver is required")
  if config.mode == cmUser and config.identity.uid <= 0:
    runtimeFail(ecUsage, "user mode requires the daemon user's identity")
  BackendRuntime(config: config, driver: driver,
    cores: initTable[string, CoreEntry](), bindings: initTable[string, Binding]())

proc toEnvironment(values: OrderedTable[string, string]): Environment =
  result = initTable[string, string]()
  for key, value in values: result[key] = value

proc specFor(runtime: BackendRuntime; entry: CoreEntry; op: ResolvedOp;
             custom, persistent: bool; request: Option[ProtocolMessage]): ProcessSpec =
  ## Built at every spawn; raises `CoreError` with the §18 code on failure.
  let core = entry.manifest.name
  var verified: VerifiedExecutable
  if custom:
    if runtime.config.runnerPath.len == 0: runtimeFail(ecInit, "no Kongue runner configured", core)
    verified = openVerifiedExecutable(runtime.config.runnerPath, runtime.config.runnerTrustedUid)
    result.executable = runtime.config.runnerPath
  else:
    let path = entry.dirs.root / op.executable
    verified = openVerifiedExecutable(path, runtime.config.trustedUid, beneath = entry.dirs.root)
    result.executable = path
    result.arguments = op.arguments
  result.executableFd = some(verified.fd)
  try:
    var operation = OperationVariables()
    if request.isSome:
      operation = OperationVariables(name: request.get.op, unit: request.get.unit,
        requestId: request.get.id, args: operationArguments(request.get.args))
    let store = if runtime.config.mode == cmUser and not runtime.config.userStore.isNil:
                  runtime.config.userStore() else: initTable[string, string]()
    let env = buildEnvironment(runtime.config.mode, runtime.config.identity,
      runtime.config.runtimeDir, runtime.config.canonicalRuntimeDir, store,
      toEnvironment(op.environment),
      CoreVariables(name: core, root: entry.dirs.root, stateDir: entry.dirs.stateDir,
        runtimeDir: entry.dirs.runtimeDir, mode: runtime.config.mode),
      operation, includeOperation = not persistent and request.isSome)
    result.environment = toEnvPairs(env)
    # §13.1: working_directory defaults to "/".
    result.workingDirectory = if op.workingDirectory.len == 0: "/" else: op.workingDirectory
    result.protocol = true
    result.cgroupProcs = entry.cgroupProcs
    if runtime.config.mode == cmSystem and op.user.len > 0:
      let identity = resolveIdentity(op.user)
      if identity.uid != geteuid() or identity.gid != getegid():
        result.applyIdentity(identity)
    if op.sandbox:
      try:
        result.sandbox = some(prepareSandbox(SandboxConfig(
          stateDir: entry.dirs.stateDir, runtimeDir: entry.dirs.runtimeDir,
          writablePaths: op.writablePaths, workingDirectory: result.workingDirectory,
          network: op.network,
          forbiddenRoots: if runtime.config.mode == cmSystem: runtime.config.forbiddenRoots
                          else: @[]),
          # §7.4 item 10: user mode uses unprivileged user namespaces.
          userNamespace = runtime.config.mode == cmUser or geteuid() != 0))
      except SandboxError as error:
        runtimeFail(ecSandbox, error.msg, core)
  except EnvironmentError as error:
    closeFd(verified.fd)
    runtimeFail(ecUsage, error.msg, core)
  except CatchableError:
    closeFd(verified.fd)
    raise

proc registerManifest*(runtime: BackendRuntime; core: CoreManifest;
                       dirs: CoreDirectories; cgroupProcs: string) =
  ## Resolve the manifest once. An executable may serve both oneshot and
  ## persistent entries; only its persistent entries share one process, and
  ## its hello `operations` are every operation routed to it (§17.2).
  if runtime.cores.hasKey(core.name): runtimeFail(ecCoreState, "core already registered", core.name)
  var entry = CoreEntry(manifest: core, dirs: dirs, cgroupProcs: cgroupProcs,
    routed: initTable[string, seq[string]]())
  var persistentOps = initOrderedTable[string, ResolvedOp]()
  for op in core.resolveOps(runtime.config.mode):
    let info = findOperation(core.manifestVersion, op.name)
    if info.isNone: continue
    case op.backend
    of manifest.bkExec:
      entry.routed.mgetOrPut(op.executable, @[]).add op.name
      var binding = Binding(core: core.name, op: op, info: info.get)
      if op.execMode == manifest.emPersistent:
        binding.persistentName = persistentName(core.name, op.executable)
        if persistentOps.hasKey(op.executable):
          let first = persistentOps[op.executable]
          # §13.3: shared persistent entries must agree on process options.
          if first.user != op.user or first.arguments != op.arguments or
              first.workingDirectory != op.workingDirectory or
              first.environment != op.environment:
            runtimeFail(ecManifest, "persistent entries of " & op.executable &
              " differ in process options", core.name)
        else:
          persistentOps[op.executable] = op
      runtime.bindings[bindingKey(core.name, op.name)] = binding
    of manifest.bkCustom:
      runtime.bindings[bindingKey(core.name, op.name)] =
        Binding(core: core.name, op: op, info: info.get)
    else: discard
  runtime.cores[core.name] = entry
  for executable, op in persistentOps:
    let name = persistentName(core.name, executable)
    let rt = runtime
    let coreName = core.name
    let resolved = op
    entry.persistent.add name
    runtime.driver.registerPersistent(name, core.name, entry.routed[executable],
      proc(): ProcessSpec =
        rt.specFor(rt.cores[coreName], resolved, false, true, none(ProtocolMessage)))
  runtime.cores[core.name] = entry

proc startPersistent*(runtime: BackendRuntime; core: string; nowMs: int64) =
  ## §20.3: persistent adapters start during load.
  if not runtime.cores.hasKey(core): runtimeFail(ecCoreUnloaded, "core is not registered", core)
  for name in runtime.cores[core].persistent:
    runtime.driver.startPersistent(name, nowMs)

proc unloadCore*(runtime: BackendRuntime; core: string; nowMs: int64) =
  ## §17.6: close descriptor 3, wait 5 seconds, then §13.7 cancellation.
  if not runtime.cores.hasKey(core): return
  for name in runtime.cores[core].persistent:
    runtime.driver.unload(name, nowMs)

proc newRequestId*(runtime: BackendRuntime): string =
  inc runtime.nextRequest
  $getpid() & "-" & $runtime.nextRequest

proc dispatch*(runtime: BackendRuntime; core, operation, unit: string;
               args: JsonNode; nowMs: int64; requestId = ""): string =
  ## Start one request; returns its id. The completion arrives through
  ## `takeCompletion`/`waitFor`.
  let key = bindingKey(core, operation)
  if not runtime.bindings.hasKey(key):
    runtimeFail(ecUnsupported, "operation has no executable backend: " & operation, core)
  let binding = runtime.bindings[key]
  let entry = runtime.cores[core]
  let id = if requestId.len == 0: runtime.newRequestId() else: requestId
  let custom = binding.op.backend == manifest.bkCustom
  var message: ProtocolMessage
  try:
    message = protocol.request(id, operation, unit,
      if args.isNil: newJObject() else: args,
      deadlineAfter(binding.op.timeoutMs),
      if custom: binding.op.handler else: "")
  except ProtocolError as error:
    runtimeFail(ecUsage, error.msg, core)
  let lock = selectLock(binding.info, core, unit)
  let timeout = binding.op.timeoutMs
  let rt = runtime
  let op = binding.op
  if custom:
    runtime.driver.submitRunner(RuntimeRunnerName & "/" & core, core, message,
      proc(): ProcessSpec = rt.specFor(rt.cores[core], op, true, false, some(message)),
      nowMs, timeout, lock)
  elif binding.persistentName.len > 0:
    runtime.driver.submitPersistent(binding.persistentName, message, nowMs, timeout, lock)
  else:
    runtime.driver.submitOneshot(persistentName(core, op.executable), core,
      entry.routed[op.executable], message,
      proc(): ProcessSpec = rt.specFor(rt.cores[core], op, false, false, some(message)),
      nowMs, timeout, lock)
  id

proc cancel*(runtime: BackendRuntime; requestId: string; nowMs: int64) =
  runtime.driver.cancel(requestId, nowMs)

proc pump*(runtime: BackendRuntime; nowMs: int64) = runtime.driver.pump(nowMs)
proc advance*(runtime: BackendRuntime; nowMs: int64) = runtime.driver.advance(nowMs)

proc takeCompletion*(runtime: BackendRuntime; requestId: string): Option[Completion] =
  runtime.driver.takeCompletion(requestId)

proc takeCompletions*(runtime: BackendRuntime): seq[Completion] =
  runtime.driver.takeCompletions()

proc waitFor*(runtime: BackendRuntime; requestId: string): Completion =
  runtime.driver.waitFor(requestId)

proc raiseOnFailure*(completion: Completion; core = ""): JsonNode =
  ## The result, or a `CoreError` carrying the completion's §18 code.
  if not completion.ok: raise newCoreError(completion.code, completion.detail, core)
  completion.value

proc run*(runtime: BackendRuntime; core, operation, unit: string;
          args: JsonNode): JsonNode =
  ## Synchronous convenience: dispatch, wait, and return the validated result.
  let id = runtime.dispatch(core, operation, unit, args, monotonicMs())
  raiseOnFailure(runtime.waitFor(id), core)

# ---------------------------------------------------------------------------
# Core lifecycle processes (§20.3 steps 6-8, §20.4 steps 4-5)

const
  LifecycleTimeoutMs* = 60_000'i64
    ## §20.3 step 6, §20.4 step 4: `init` and `shutdown` have a fixed timeout.
  LifecycleOperation = "core.verify"
    ## `init`/`shutdown` have no operation (§16.2); the request still needs a
    ## well-formed `op`, which the runner ignores for lifecycle functions.

proc isRegistered*(runtime: BackendRuntime; core: string): bool =
  runtime.cores.hasKey(core)

proc manifestOf*(runtime: BackendRuntime; core: string): CoreManifest =
  if not runtime.cores.hasKey(core): runtimeFail(ecCoreUnloaded, "core is not registered", core)
  runtime.cores[core].manifest

proc setCgroupProcs*(runtime: BackendRuntime; core, cgroupProcs: string) =
  if runtime.cores.hasKey(core): runtime.cores[core].cgroupProcs = cgroupProcs

proc applyAccount(runtime: BackendRuntime; spec: var ProcessSpec; account: string) =
  ## System mode: run as `account` (§10.4, §13.1). User mode ignores it (§7.4).
  if runtime.config.mode == cmSystem and account.len > 0:
    let identity = resolveIdentity(account)
    if identity.uid != geteuid() or identity.gid != getegid():
      spec.applyIdentity(identity)

proc lifecycleSpec(runtime: BackendRuntime; core: string): ProcessSpec =
  ## `init`/`shutdown`: a Kongue runner, unsandboxed, as `account`, with the
  ## base environment, the user store and the core's `JUMPSTART_*` variables.
  let entry = runtime.cores[core]
  if runtime.config.runnerPath.len == 0: runtimeFail(ecInit, "no Kongue runner configured", core)
  let verified = openVerifiedExecutable(runtime.config.runnerPath, runtime.config.runnerTrustedUid)
  result.executable = runtime.config.runnerPath
  result.executableFd = some(verified.fd)
  try:
    let store = if runtime.config.mode == cmUser and not runtime.config.userStore.isNil:
                  runtime.config.userStore() else: initTable[string, string]()
    let env = buildEnvironment(runtime.config.mode, runtime.config.identity,
      runtime.config.runtimeDir, runtime.config.canonicalRuntimeDir, store,
      initTable[string, string](),
      CoreVariables(name: core, root: entry.dirs.root, stateDir: entry.dirs.stateDir,
        runtimeDir: entry.dirs.runtimeDir, mode: runtime.config.mode),
      OperationVariables(), includeOperation = false)
    result.environment = toEnvPairs(env)
    result.workingDirectory = "/"
    result.protocol = true
    result.cgroupProcs = entry.cgroupProcs
    runtime.applyAccount(result, entry.manifest.account)
  except EnvironmentError as error:
    closeFd(verified.fd)
    runtimeFail(ecUsage, error.msg, core)
  except CatchableError:
    closeFd(verified.fd)
    raise

proc runLifecycle*(runtime: BackendRuntime; core, function: string; nowMs: int64;
                   timeoutMs = LifecycleTimeoutMs): string =
  ## Start `init` or `shutdown` (§20.3 step 6, §20.4 step 4); returns the
  ## request id. The completion arrives like any other.
  if not runtime.cores.hasKey(core): runtimeFail(ecCoreUnloaded, "core is not registered", core)
  if function notin ["init", "shutdown"]: runtimeFail(ecUsage, "not a lifecycle function: " & function, core)
  let id = runtime.newRequestId()
  let message = protocol.request(id, LifecycleOperation, "", newJObject(),
    deadlineAfter(timeoutMs), function)
  let rt = runtime
  runtime.driver.submitLifecycle(RuntimeRunnerName & "/" & core & "/" & function, core,
    message, proc(): ProcessSpec = rt.lifecycleSpec(core), nowMs, timeoutMs)
  id

proc supervisorSpec*(runtime: BackendRuntime; core: string): ProcessSpec =
  ## §15.2: the declared supervisor, verified beneath the core directory, in
  ## the core's `control/` cgroup, as `user` (default `account`), with the
  ## supervisor's `environment` as layer 3 (§7.5).
  if not runtime.cores.hasKey(core): runtimeFail(ecCoreUnloaded, "core is not registered", core)
  let entry = runtime.cores[core]
  let sup = entry.manifest.supervisor
  let path = entry.dirs.root / sup.executable
  let verified = openVerifiedExecutable(path, runtime.config.trustedUid, beneath = entry.dirs.root)
  result.executable = path
  result.executableFd = some(verified.fd)
  result.arguments = sup.arguments
  try:
    let store = if runtime.config.mode == cmUser and not runtime.config.userStore.isNil:
                  runtime.config.userStore() else: initTable[string, string]()
    let env = buildEnvironment(runtime.config.mode, runtime.config.identity,
      runtime.config.runtimeDir, runtime.config.canonicalRuntimeDir, store,
      toEnvironment(sup.environment),
      CoreVariables(name: core, root: entry.dirs.root, stateDir: entry.dirs.stateDir,
        runtimeDir: entry.dirs.runtimeDir, mode: runtime.config.mode),
      OperationVariables(), includeOperation = false)
    result.environment = toEnvPairs(env)
    result.workingDirectory = if sup.workingDirectory.len == 0: "/" else: sup.workingDirectory
    result.protocol = true
    result.supervisorSubreaper = true
    result.cgroupProcs = entry.cgroupProcs
    runtime.applyAccount(result, if sup.user.len > 0: sup.user else: entry.manifest.account)
  except EnvironmentError as error:
    closeFd(verified.fd)
    runtimeFail(ecUsage, error.msg, core)
  except CatchableError:
    closeFd(verified.fd)
    raise

proc hasPersistent*(runtime: BackendRuntime; core: string): bool =
  runtime.cores.hasKey(core) and runtime.cores[core].persistent.len > 0

proc persistentStates*(runtime: BackendRuntime; core: string): seq[AdapterState] =
  ## Handshake progress of the core's persistent adapters (§17.6).
  if not runtime.cores.hasKey(core): return
  for name in runtime.cores[core].persistent:
    result.add runtime.driver.manager.state(name)

proc persistentRunning*(runtime: BackendRuntime; core: string): bool =
  ## True while any persistent adapter process of the core is alive.
  if not runtime.cores.hasKey(core): return false
  for name in runtime.cores[core].persistent:
    if runtime.driver.running(name): return true

proc forgetCore*(runtime: BackendRuntime; core: string) =
  ## Drop an unloaded core's bindings, so a later load registers afresh
  ## (§20.3 step 2: nothing from an earlier load is reused).
  if not runtime.cores.hasKey(core): return
  var stale: seq[string]
  for key, binding in runtime.bindings:
    if binding.core == core: stale.add key
  for key in stale: runtime.bindings.del(key)
  runtime.cores.del(core)

proc hasBinding*(runtime: BackendRuntime; core, operation: string): bool =
  runtime.bindings.hasKey(bindingKey(core, operation))
