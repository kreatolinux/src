## Startup (§20.2 steps 3-6) and shutdown (§20.8, §20.9), and `serve`.
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
import ./daemon_lifecycle
import ./daemon_jobs
import ./daemon_requests
import ./daemon_loop

# ---------------------------------------------------------------------------
# Startup (§20.2 steps 3-6)

proc startupSteps*(d: Daemon) =
  d.rediscover()
  try:
    d.enabled = readEnabledState(d.config.statePaths).enabled
  except CoreError as e:
    # §20.2 step 4: a fixed rule, not a fallback.
    d.stateError = some((e.code, e.msg))
    d.log(clError, "", errorName(e.code) & ": " & e.msg & "; loading serviceHandler only")
    d.enabled = @[NativeCore]
  except CatchableError as e:
    d.stateError = some((ecState, e.msg))
    d.log(clError, "", "E_STATE: " & e.msg & "; loading serviceHandler only")
    d.enabled = @[NativeCore]
  try: nameidx.load(d.nameIndexes, d.enabled)
  except CatchableError as e: d.log(clWarn, "", "name indexes not read: " & e.msg)
  var discoveredNames = initHashSet[string]()
  for found in d.discovered.cores: discoveredNames.incl found.name
  var loadable: seq[string]
  for name in d.enabled:
    if name in discoveredNames:
      loadable.add name
      continue
    var reason = "E_NOT_FOUND: enabled core was not discovered"
    if d.discoveryError.isSome:
      reason = errorName(d.discoveryError.get[0]) & ": core discovery failed: " &
        d.discoveryError.get[1]
    for rejected in d.discovered.rejected:
      if rejected.name == name:
        reason = errorName(coreErrorCode(rejected.code)) & ": " & rejected.reason
    discard d.registry.markFailed(name, reason)
    d.log(clError, name, reason)
  # Delegation targets come from discovery (§20.2 step 5).
  for found in d.discovered.cores:
    let p = d.registry.ensureCore(found.name)
    d.registry.cores[p].delegatesTo = found.delegationTargets
  var order = loadable
  let ordered = d.registry.delegationOrder(loadable)
  if ordered.ok: order = ordered.value
  else: d.log(clError, "", "delegation order: " & ordered.error.message)
  for name in order:
    d.startupPending.incl name
    d.lifecycleQueue.addLast LifecycleTask(kind: lkLoad, core: name, startup: true)

proc startup*(d: Daemon) =
  ## Discover, read the enabled state, and queue the loads in delegation
  ## order. The loads run from the event loop; requests are served meanwhile.
  ## A failure here never stops the daemon (it may be PID 1): it still loads
  ## serviceHandler (§20.2 step 4's rule).
  if d.config.mode == cmSystem and not d.filesystemsReady:
    d.filesystemsDeadlineMs = nowMs() + (if d.config.filesystemsWaitMs > 0:
      d.config.filesystemsWaitMs else: FilesystemsWaitMs)
  try: d.startupSteps()
  except Exception as e:
    d.log(clError, "", "startup failed: " & $e.name & ": " & e.msg &
      "; loading serviceHandler only")
    d.enabled = @[NativeCore]
    d.startupPending.clear()
    d.lifecycleQueue.clear()
    d.startupPending.incl NativeCore
    d.lifecycleQueue.addLast LifecycleTask(kind: lkLoad, core: NativeCore, startup: true)

# ---------------------------------------------------------------------------
# Shutdown (§20.8, §20.9)

proc unloadForShutdown*(d: Daemon; core: string; deadlineMs: int64): bool =
  let state = d.stateOf(core)
  if not state.isLoaded: return true
  d.unloadDeadlineMs = deadlineMs
  defer: d.unloadDeadlineMs = 0
  d.frames.add fkLifecycle
  defer: discard d.frames.pop()
  let busy = d.busySnapshot(core)
  let outcome = d.registry.executeUnload(core, busy, d.unloadCallbacks(),
    UnloadOptions(stopUnits: true, daemonShutdown: true))
  if not outcome.ok:
    d.log(clError, core, "unload during shutdown failed: " & outcome.error.message)
  outcome.ok and nowMs() < deadlineMs

proc forceUnloaded*(d: Daemon; core: string) =
  ## §20.8 step 3: after the limit, kill the cgroup and mark it unloaded.
  try:
    d.backend.unloadCore(core, nowMs())
    if d.info.hasKey(core) and not d.info[core].supervisor.isNil:
      closeSupervisorRuntime(d.info[core].supervisor)
      d.info[core].supervisor = nil
    discard d.host.killCgroupStep()(core)
    discard d.host.removeRuntimeDirStep()(core)
  except CatchableError as e: d.log(clWarn, core, "forced unload: " & e.msg)
  d.forget(core)
  let p = d.pos(core)
  if p >= 0: d.registry.cores[p].state = csUnloaded

proc closeSocket*(d: Daemon) =
  if not d.transport.isNil: d.transport.close()
  try:
    if d.config.paths.socketPath.len > 0: removeFile(d.config.paths.socketPath)
  except CatchableError: discard

proc monoSeconds*(): float = float(nowMs()) / 1000.0

proc runShutdownSequence*(d: Daemon) =
  if d.shutdownRunning: return
  d.shutdownRunning = true
  d.shuttingDown = true
  let rt = d
  let mode = modeShutdown(d.config.mode)
  var plan = ShutdownPlan(mode: mode, cores: d.loadOrder)
  let enter = proc() = rt.shuttingDown = true
  let close = proc() = rt.closeSocket()
  let unload = proc(name: string; deadline: float): bool =
    rt.unloadForShutdown(name, int64(deadline * 1000.0))
  let logFailure = proc(step, message: string) =
    rt.log(clError, "", "shutdown: " & step & ": " & message)
  var ops: ShutdownOps
  # Without the PID 1 system operations (test builds), system mode stops
  # its cores the way user mode does and then exits.
  if mode == smSystem and not d.config.linuxSystem.reboot.isNil:
    if not d.config.sessions.runningUsers.isNil:
      try: plan.users = d.config.sessions.runningUsers()
      except CatchableError: discard
    var config = d.config.linuxShutdown
    config.coreCgroup = proc(name: string): string =
      if rt.host.hasCgroup(name): rt.host.layout(name).core else: ""
    config.markCoreUnloaded = proc(name: string) = rt.forceUnloaded(name)
    var sys = d.config.linuxSystem
    sys.pause = proc(ms: int) = rt.runOnce(ms)
    sys.now = monoSeconds       # the same clock as unloadForShutdown's deadlines
    ops = linuxShutdownOps(config, sys, enter, close, unload, logFailure)
  else:
    ops = ShutdownOps(now: monoSeconds, enterShutdown: enter, unloadCore: unload,
      killCoreCgroup: proc(name: string) = rt.forceUnloaded(name),
      closeSocket: close, logFailure: logFailure,
      finalAction: proc(action: FinalAction) =
        rt.exitRequested = true
        rt.exitStatus = 0)
    if mode == smSystem:
      # Test builds: no PID 1 steps beyond the cores.
      ops.signalUser = proc(uid: int; signal: ShutdownSignal) = discard
      ops.waitUser = proc(uid: int; deadline: float): bool = true
      ops.killUserCgroup = proc(uid: int) = discard
      ops.signalRemaining = proc(signal: ShutdownSignal) = discard
      ops.waitRemaining = proc(deadline: float): bool = true
      ops.deactivateSwap = proc() = discard
      ops.unmountFilesystems = proc() = discard
      ops.remountRootReadOnly = proc() = discard
      ops.syncFilesystems = proc() = discard
  try: runShutdown(d.shutdownState, plan, ops)
  except CatchableError as e: d.log(clError, "", "shutdown: " & e.msg)
  d.exitRequested = true
  if not d.config.logger.isNil:
    try: discard d.config.logger.flush()
    except CatchableError: discard

proc serve*(d: Daemon) =
  ## Run until the shutdown sequence ends (user mode exits; system mode never
  ## returns from the final reboot). Nothing that happens in a turn ends the
  ## loop early (see `runOnce`).
  while not d.exitRequested:
    d.guarded("loop turn"): d.runOnce(IdlePollMs)
    if d.shutdownRequested and not d.shutdownRunning and d.depth == 0:
      try: d.runShutdownSequence()
      except Exception as e:
        d.loopFault("shutdown", e)
        d.exitRequested = true
