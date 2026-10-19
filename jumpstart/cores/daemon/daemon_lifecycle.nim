## Core lifecycle callbacks (§20.3-§20.5), activation (§20.6) and the startup
## tail (§20.2 steps 1 and 7).
import std/[algorithm, deques, json, monotimes, options, os, posix, sets, strutils,
  tables]
import ../backends/[adapter, adapter_runtime, backend_runtime, extension_runtime, supervisor_runtime],
  ../manifest/[coredirs, discovery, manifest, modes, types],
  ./[control, control_transport, core_host, logging, server, shutdown, shutdown_linux],
  ../lifecycle/[dispatch, lifecycle, lifecycle_exec, routing, runtime_resources, state],
  ../native/native_api,
  ../sessions/[session_manager, sessions]
import jumpstartcore/[cgroups, environment, errors, names, peercred, protocol, reaper, registry]
import ../manifest/nameindex as nameidx
import ../lifecycle/resources as res
import jumpstartcore/registry_types as regtypes
import ./daemon_state
import ./daemon_calls
import ./daemon_events
import ./daemon_routing
import ./daemon_cores

# ---------------------------------------------------------------------------
# Lifecycle (§20.3-§20.5)

proc rediscover*(d: Daemon) =
  try:
    d.discovered = discoverCores(d.config.mode, d.config.roots,
      manifestInspector(d.config.mode, d.config.version), d.config.discoveryOptions)
    d.discoveryError = none((CoreErrorCode, string))
  except CatchableError as e:
    # An insecure or unreadable root (§8.3): only the built-in core remains,
    # and the real error (E_PERMISSION, E_IO, ...) is what `cores status`
    # shows for the cores that could not be found.
    d.log(clError, "", "discovery failed: " & e.msg)
    let code = if e of CoreError: (ref CoreError)(e).code else: ecIo
    d.discoveryError = some((code, e.msg))
    d.discovered = DiscoveryResult(cores: @[discovery.DiscoveredCore(name: NativeCore)])
  for found in d.discovered.cores: discard d.registry.ensureCore(found.name)

proc busySnapshot*(d: Daemon; core: string): BusySnapshot =
  ## §20.4 precondition 4.
  let (available, populated) = d.host.unitsPopulated(core)
  result.cgroupAvailable = available
  result.cgroupPopulated = populated
  if d.stateOf(core) != csLoaded: return
  if core.isNative:
    try: result.units = d.config.native.units()
    except CatchableError as e: d.log(clWarn, core, "unit snapshot failed: " & e.msg)
    return
  if not d.supports(core, "unit.list"): return
  let listed = d.callSync(core, "unit.list", "", newJObject())
  if not listed.ok:
    d.log(clWarn, core, "unit.list for the busy check failed: " & listed.message)
    return
  d.afterList(core, listed)
  var subsystems = initTable[string, string]()
  for item in listed.value{"units"}.getElems:
    let name = item{"name"}.getStr
    let subsystem = item{"subsystem"}.getStr
    if name.len == 0 or subsystem.len == 0: continue
    subsystems[name] = subsystem
    var snapshot = UnitSnapshot(name: name, subsystem: subsystem,
      enabled: item{"enablement"}.getStr == "enabled")
    let op = subsystem & ".status"
    if d.supports(core, op):
      let status = d.callSync(core, op, name, newJObject())
      if status.ok:
        snapshot.state = case status.value{"state"}.getStr
          of "active": ursActive
          of "activating": ursActivating
          of "deactivating": ursDeactivating
          of "reloading": ursReloading
          of "failed": ursFailed
          else: ursInactive
    result.units.add snapshot
  d.infoOf(core).unitSubsystems = subsystems

proc stopAdaptersStep*(d: Daemon; core: string): CoreResult[bool] =
  d.backend.unloadCore(core, nowMs())
  let rt = d
  if not d.waitUntil(proc(): bool = not rt.backend.persistentRunning(core),
      d.effectiveDeadline(nowMs() + AdapterStartSlackMs)):
    if rt.backend.persistentRunning(core):
      return failure[bool](ecTimeout, "persistent adapters did not stop in time")
  success(true)

proc stopSupervisorStep*(d: Daemon; core: string): CoreResult[bool] =
  if not d.info.hasKey(core) or d.info[core].supervisor.isNil: return success(true)
  let runtime = d.info[core].supervisor
  let p = d.pos(core)
  var scratch = if p >= 0: d.registry.cores[p] else: CoreRuntime(name: core)
  let rt = d
  let stopped = runtime.stopSupervisorBlocking(scratch, proc(): int64 = nowMs(),
    proc(ms: int) = rt.runOnce(ms))
  closeSupervisorRuntime(runtime)
  d.info[core].supervisor = nil
  if stopped: success(true)
  else: failure[bool](ecBackend, "supervisor did not exit")

proc runShutdownStep*(d: Daemon; core: string): CoreResult[bool] =
  if core.isNative or not d.info.hasKey(core) or not d.info[core].initDone: return success(true)
  d.info[core].initDone = false
  if not d.backend.isRegistered(core) or not d.info[core].manifest.hasFunction("shutdown"):
    return success(true)
  try:
    let id = d.backend.runLifecycle(core, "shutdown", nowMs())
    let done = d.waitRequest(id, nowMs() + InitTimeoutMs + 6_000)
    if done.ok: success(true)
    else: failure[bool](done.code, "shutdown: " & done.detail)
  except CoreError as e: failure[bool](e.code, e.msg)

proc abortCall*(d: Daemon; call: Call; code: CoreErrorCode; message: string) =
  ## End a call that can no longer complete (its core goes away): the job
  ## waiting for it gets an answer and no bookkeeping is left behind.
  case call.state
  of clQueued:
    discard d.resources.cancelQueuedOperation(call.target, call.klass, call.ticket)
    d.queuedCalls.del(callKey(call.target, call.klass, call.ticket))
  of clNativeWait:
    var kept = initDeque[int]()
    for id in d.nativeQueue:
      if id != call.id: kept.addLast id
    d.nativeQueue = kept
  of clRunning:
    if call.requestId.len > 0: d.backend.cancel(call.requestId, nowMs())
  else: discard
  d.finishCall(call, errResult(code, message))

proc finishCallsOf*(d: Daemon; core: string) =
  var pending: seq[Call]
  for call in d.calls.values:
    if call.state != clDone and (call.core == core or call.target == core):
      pending.add call
  for call in pending:
    if d.shuttingDown:
      d.abortCall(call, ecShutdown, core & " was unloaded: the daemon is shutting down")
    else:
      d.abortCall(call, ecCoreUnloaded, core & " was unloaded before the operation finished")

proc forget*(d: Daemon; core: string) =
  d.finishCallsOf(core)
  d.backend.forgetCore(core)
  d.plans.del(core)
  let at = d.loadOrder.find(core)
  if at >= 0: d.loadOrder.delete(at)
  discard d.resources.forgetCore(core)
  if d.info.hasKey(core):
    d.info[core].closed = false
    d.info[core].initDone = false
    d.info[core].stateDirDone = false

proc scheduleActivation*(d: Daemon; core: string; startup: bool)

proc trustedParent*(d: Daemon; path: string): CoreResult[bool] =
  ## §8.3: the per-core directory roots outside the core roots are real
  ## directories owned by the trusted user (or root), not group/other
  ## writable, before anything is created beneath them.
  try:
    checkTrustedDirectory(path, d.config.statePaths.trustedUid)
    success(true)
  except CoreError as e: failure[bool](e.code, e.msg)
  except CatchableError as e: failure[bool](ecPermission, e.msg)

proc loadCallbacks*(d: Daemon; startup: bool): LoadCallbacks =
  let rt = d
  var manifestFor = initTable[string, CoreManifest]()
  result = newLoadCallbacks(
    discoverValidate = proc(core: string): CoreResult[lifecycle_exec.DiscoveredCore] =
      if core.isNative:
        if not rt.config.native.available:
          return failure[lifecycle_exec.DiscoveredCore](ecInit, "serviceHandler is unavailable")
        return success(lifecycle_exec.DiscoveredCore(activation: asCore,
          hasUnitSubsystem: true, extension: false))
      rt.rediscover()
      var found: discovery.DiscoveredCore
      var ok = false
      for item in rt.discovered.cores:
        if item.name == core: (found, ok) = (item, true)
      if not ok:
        for rejected in rt.discovered.rejected:
          if rejected.name == core:
            return failure[lifecycle_exec.DiscoveredCore](coreErrorCode(rejected.code),
              rejected.reason)
        if rt.discoveryError.isSome:
          return failure[lifecycle_exec.DiscoveredCore](rt.discoveryError.get[0],
            "core discovery failed: " & rt.discoveryError.get[1])
        return failure[lifecycle_exec.DiscoveredCore](ecNotFound, "core not found: " & core)
      let m = loadExtensionManifest(found, rt.config.version)
      manifestFor[core] = m
      let ops = m.resolveOps(rt.config.mode)
      success(lifecycle_exec.DiscoveredCore(metadata: manifestMetadata(m.path),
        delegatesTo: delegationTargets(ops), activation: m.activation,
        hasUnitSubsystem: m.claimsUnit, extension: true,
        hasSupervisor: m.hasSupervisor,
        hasPersistentAdapters: block:
          var persistent = false
          for op in ops:
            if op.backend == manifest.bkExec and op.execMode == emPersistent: persistent = true
          persistent)),
    resolveOperations = proc(core: string): CoreResult[bool] =
      var info = CoreInfo(native: core.isNative)
      if core.isNative:
        info.plan = nativePlan(rt.config.version, rt.config.mode)
        info.claimsUnit = true
      else:
        let m = manifestFor[core]
        info.manifest = m
        info.plan = planFor(m, rt.config.mode)
        info.claimsUnit = m.claimsUnit
        var plans = rt.plans
        plans[core] = info.plan
        # §20.3 step 3: every delegation chain resolves to a loaded target.
        for op, entry in info.plan.operations:
          if entry.backend.kind != dispatch.bkDelegate: continue
          try: discard resolveDispatch(plans, core, op)
          except CoreError as e:
            if e.code != ecUnsupported: return failure[bool](e.code, e.msg)
      rt.info[core] = info
      rt.host.checkCgroupStep()(core),
    createCgroup = rt.host.createCgroupStep(),
    createRuntimeDir = proc(core: string): CoreResult[bool] =
      let trusted = rt.trustedParent(rt.config.paths.runtimeRoot)
      if not trusted.ok: return trusted
      rt.host.createRuntimeDirStep()(core),
    filesystemsReady = proc(): bool = rt.filesystemsReady,
    createStateDir = proc(core: string): CoreResult[bool] =
      let trusted = rt.trustedParent(rt.config.paths.stateRoot)
      if not trusted.ok: return trusted
      result = rt.host.createStateDirStep()(core)
      if result.ok: rt.infoOf(core).stateDirDone = true,
    runInit = proc(core: string): CoreResult[bool] =
      if core.isNative:
        let layout = if rt.host.hasCgroup(core): some(rt.host.layout(core)) else: none(CoreCgroups)
        try:
          rt.config.native.load(layout)
          rt.infoOf(core).initDone = true
          return success(true)
        except CoreError as e: return failure[bool](e.code, e.msg)
        except CatchableError as e: return failure[bool](ecInit, e.msg)
      let m = rt.info[core].manifest
      let dirs = rt.host.directories(core)
      try:
        rt.backend.forgetCore(core)
        rt.backend.registerManifest(m, backend_runtime.CoreDirectories(root: m.directory,
          stateDir: dirs.stateDir, runtimeDir: dirs.runtimeDir), rt.host.controlProcs(core))
        let id = rt.backend.runLifecycle(core, "init", nowMs())
        let done = rt.waitRequest(id, nowMs() + InitTimeoutMs + 6_000)
        rt.infoOf(core).initDone = true   # §20.3 rollback runs shutdown
        if done.ok: success(true)
        else: failure[bool](ecInit, "init: " & errorName(done.code) & ": " & done.detail)
      except CoreError as e: failure[bool](ecInit, e.msg)
      except CatchableError as e: failure[bool](ecInit, e.msg),
    startSupervisor = proc(core: string): CoreResult[bool] =
      try:
        let m = rt.info[core].manifest
        let spec = rt.backend.supervisorSpec(core)
        let runtime = startSupervisor(spec, rt.reaper, core, modeText(rt.config.mode),
          runningVersionNumber(rt.config.version), nowMs(), m.supervisor.readyTimeoutMs)
        if spec.executableFd.isSome: discard posix.close(spec.executableFd.get)
        if not rt.logging.isNil: attachSupervisorLogging(runtime, rt.logging)
        let ready = runtime.awaitSupervisorReady(proc(): int64 = nowMs(),
          proc(ms: int) = rt.runOnce(ms))
        if not ready.ok:
          closeSupervisorRuntime(runtime)
          return ready
        rt.infoOf(core).supervisor = runtime
        success(true)
      except CoreError as e: failure[bool](ecInit, e.msg)
      except CatchableError as e: failure[bool](ecInit, e.msg),
    startAdapters = proc(core: string): CoreResult[bool] =
      try:
        rt.backend.startPersistent(core, nowMs())
        var failed = ""
        let ok = rt.waitUntil(proc(): bool =
          for state in rt.backend.persistentStates(core):
            if state in {asFailed, asDegraded, asStopped}:
              failed = $state
              return true
            if state != asReady: return false
          true, nowMs() + AdapterStartSlackMs)
        if not ok: return failure[bool](ecInit, "persistent adapter handshake timed out")
        if failed.len > 0: return failure[bool](ecInit, "persistent adapter failed to start")
        success(true)
      except CoreError as e: failure[bool](ecInit, e.msg),
    publish = proc(core: string): CoreResult[bool] =
      rt.plans[core] = rt.info[core].plan
      if core notin rt.loadOrder: rt.loadOrder.add core
      success(true),
    seedNameIndex = proc(core: string): CoreResult[bool] =
      if not rt.supports(core, "unit.list"): return success(true)
      let listed = rt.callSync(core, "unit.list", "", newJObject())
      if not listed.ok: return failure[bool](listed.code, listed.message)
      rt.afterList(core, listed)
      success(true),
    scheduleActivation = proc(core: string): CoreResult[bool] =
      rt.scheduleActivation(core, startup)
      success(true),
    stopAdapters = proc(core: string): CoreResult[bool] = rt.stopAdaptersStep(core),
    stopSupervisor = proc(core: string): CoreResult[bool] = rt.stopSupervisorStep(core),
    runShutdown = proc(core: string): CoreResult[bool] = rt.runShutdownStep(core),
    killCgroup = proc(core: string): CoreResult[bool] =
      result = rt.host.killCgroupStep()(core)
      rt.forget(core),
    removeRuntimeDir = rt.host.removeRuntimeDirStep(),
    log = proc(core, message: string) = rt.log(clInfo, core, message))

proc unloadCallbacks*(d: Daemon): UnloadCallbacks =
  let rt = d
  result = newUnloadCallbacks(
    close = proc(core: string): CoreResult[bool] =
      rt.infoOf(core).closed = true
      success(true),
    cancelStreams = proc(core: string): CoreResult[bool] =
      var streams: seq[Call]
      for id in rt.infoOf(core).activeCalls:
        let call = rt.calls.getOrDefault(id)
        if not call.isNil and not call.internal and call.targetOp == "log.follow":
          streams.add call
      for call in streams: rt.cancelCall(call)
      success(true),
    deactivateCore = proc(core: string): CoreResult[bool] =
      let r = rt.callSync(core, "unit.deactivate", "", newJObject())
      if r.ok: success(true) else: failure[bool](r.code, r.message),
    stopUnit = proc(core, unit: string): CoreResult[bool] =
      let subsystem = rt.infoOf(core).unitSubsystems.getOrDefault(unit, "service")
      var args = newJObject()
      if subsystem == "mount": args["lazy"] = %false
      let r = rt.callSync(core, subsystem & ".stop", unit, args)
      if r.ok: success(true) else: failure[bool](r.code, unit & ": " & r.message),
    reopen = proc(core: string): CoreResult[bool] =
      rt.infoOf(core).closed = false
      success(true),
    drain = proc(core: string): CoreResult[bool] =
      # Native operations of outer frames cannot finish while this frame
      # runs, so only asynchronous (extension) operations are drained.
      proc inFlight(): seq[Call] =
        for id in rt.infoOf(core).activeCalls:
          let call = rt.calls.getOrDefault(id)
          if not call.isNil and not call.native: result.add call
      let drained = rt.waitUntil(proc(): bool = inFlight().len == 0,
        rt.effectiveDeadline(nowMs() + DrainLimitMs))
      if not drained:
        # §20.4 step 3: cancel the rest (§13.7: SIGTERM, 5 s, SIGKILL) and give
        # the escalation the time it needs; whatever still has not answered is
        # ended here, so no job waits for a core that is gone.
        for call in inFlight(): rt.cancelCall(call)
        discard rt.waitUntil(proc(): bool = inFlight().len == 0,
          rt.effectiveDeadline(nowMs() + CancelSettleMs))
        for call in inFlight():
          rt.abortCall(call, ecTimeout, "operation did not finish before " & core & " unloaded")
      success(true),
    runShutdown = proc(core: string): CoreResult[bool] = rt.runShutdownStep(core),
    stopAdapters = proc(core: string): CoreResult[bool] = rt.stopAdaptersStep(core),
    stopSupervisor = proc(core: string): CoreResult[bool] = rt.stopSupervisorStep(core),
    killCgroup = rt.host.killCgroupStep(),
    removeRuntimeDir = proc(core: string): CoreResult[bool] =
      result = rt.host.removeRuntimeDirStep()(core)
      rt.forget(core),
    log = proc(core, message: string) = rt.log(clInfo, core, message))

proc runLifecycleTask*(d: Daemon; task: LifecycleTask) =
  d.lifecycleBusy = true
  d.frames.add fkLifecycle
  var outcome: CoreResult[bool]
  try:
    d.startupPending.excl task.core
    case task.kind
    of lkLoad:
      outcome = d.registry.executeLoad(task.core, d.loadCallbacks(task.startup))
    of lkUnload:
      let busy = d.busySnapshot(task.core)
      outcome = d.registry.executeUnload(task.core, busy, d.unloadCallbacks(),
        UnloadOptions(stopUnits: task.stopUnits))
    of lkReload:
      let busy = if d.stateOf(task.core).isLoaded: d.busySnapshot(task.core) else: BusySnapshot()
      outcome = d.registry.executeReload(task.core, busy, d.loadCallbacks(false),
        d.unloadCallbacks(), UnloadOptions(stopUnits: task.stopUnits))
  except CatchableError as e:
    outcome = failure[bool](uncodedErrorCode(e), e.msg)
  finally:
    discard d.frames.pop()
    d.lifecycleBusy = false
  if not outcome.ok:
    d.log(clError, task.core, errorName(outcome.error.code) & ": " & outcome.error.message)
  d.refreshEnabled()
  if not task.done.isNil:
    try: task.done(outcome)
    except CatchableError: discard

proc canStartLifecycle*(d: Daemon): bool =
  if d.lifecycleBusy: return false
  for frame in d.frames:
    if frame in {fkLifecycle, fkNativeMutating}: return false
  true

proc withCore*(response: ControlResponse; core: string): ControlResponse =
  result = response
  result.core = core

proc lifecycleJob*(d: Daemon; job: Job) =
  let request = job.request.core
  let name = request.name.get("")
  if name.len == 0:
    d.respond(job, errorResponse(ecUsage, "core name is required"))
    return
  if name == NativeCore and request.action == "load" and d.stateOf(name).isLoaded:
    d.respond(job, okResponse(%*{"changed": false}, @[]))
    return
  let kind = case request.action
    of "load": lkLoad
    of "unload": lkUnload
    else: lkReload
  if kind != lkLoad and d.pos(name) < 0:
    d.respond(job, errorResponse(ecNotFound, "core not found: " & name, name))
    return
  d.lifecycleQueue.addLast LifecycleTask(kind: kind, core: name,
    stopUnits: request.stopUnits.get(false),
    done: proc(r: CoreResult[bool]) =
      if r.ok: d.respond(job, okResponse(%*{"changed": r.value}).withCore(name))
      else: d.respond(job, errorResponse(r.error.code, r.error.message, name)))

# ---------------------------------------------------------------------------
# Activation (§20.6) and the startup tail (§20.2 steps 1 and 7)

proc activationFinished*(d: Daemon; core: string) =
  if core in d.startupActivations:
    d.startupActivations.excl core

proc startPerUnit*(d: Daemon; core: string; units: seq[(string, string)]; index: int) =
  if index >= units.len:
    d.activationFinished(core)
    return
  let (name, subsystem) = units[index]
  discard d.startCall(core, subsystem & ".start", name, newJObject(), internal = true,
    proc(r: CallResult) =
      if r.ok: d.log(clInfo, core, "activation: " & name & " started")
      else: d.log(clWarn, core, "activation of " & name & " failed: " &
        errorName(r.code) & ": " & r.message)
      d.startPerUnit(core, units, index + 1))

proc scheduleActivation*(d: Daemon; core: string; startup: bool) =
  let p = d.pos(core)
  if p < 0: return
  let rt = d.registry.cores[p]
  if not rt.hasUnitSubsystem or rt.activation == asNone: return
  if startup: d.startupActivations.incl core
  case rt.activation
  of asCore, asNative:
    if not d.supports(core, "unit.activate"):
      d.activationFinished(core)
      return
    discard d.startCall(core, "unit.activate", "", newJObject(), internal = true,
      proc(r: CallResult) =
        if r.ok: d.log(clInfo, core, "activation: done")
        else: d.log(clWarn, core, "activation failed: " & errorName(r.code) & ": " & r.message)
        d.activationFinished(core))
  of asPerUnit:
    discard d.startCall(core, "unit.list", "", newJObject(), internal = true,
      proc(r: CallResult) =
        if not r.ok:
          d.log(clWarn, core, "activation: unit.list failed: " & r.message)
          d.activationFinished(core)
          return
        d.afterList(core, r)
        var units: seq[(string, string)]
        for item in r.value{"units"}.getElems:
          if item{"enablement"}.getStr == "enabled":
            units.add (item{"name"}.getStr, item{"subsystem"}.getStr)
        d.startPerUnit(core, units, 0))
  of asNone: d.activationFinished(core)

proc checkStartupTail*(d: Daemon) =
  if d.startupDone or d.startupPending.len > 0 or d.lifecycleBusy or
      d.lifecycleQueue.len > 0 or d.startupActivations.len > 0 or d.shutdownRequested:
    return
  d.startupDone = true
  d.log(clInfo, "", "startup complete")
  if not d.filesystemsReady:
    d.markFilesystemsReady("")
  if d.config.mode == cmSystem and d.sessionsEnabled and not d.lingerStarted:
    d.lingerStarted = true
    d.sessionBusy = true        # starting a user daemon runs nested loop turns
    defer: d.sessionBusy = false
    try:
      d.sessions.loadLinger()
      for outcome in d.sessions.model.startLingeringUsers():
        if not outcome.ok: d.log(clWarn, "", "lingering user: " & outcome.message)
    except CatchableError as e: d.log(clWarn, "", "lingering users: " & e.msg)
