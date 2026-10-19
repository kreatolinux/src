## Callback-driven execution of the lifecycle state machine (§20.3-§20.6).
##
## The coordinator owns ordering, state transitions, rollback and logging,
## while all I/O, process, router and dispatch work is injected. Every
## callback is REQUIRED (§1.1: nothing is satisfied by a hidden default). A
## callback that has nothing to do for a particular core says so explicitly by
## returning success. `newLoadCallbacks`/`newUnloadCallbacks`/
## `newActivationCallbacks` take every step as a required parameter, so a
## missing step is a compile-time error; values built field by field are
## validated at run time and refused without changing any state.
import std/strutils
import ./lifecycle
export lifecycle

type
  BoolStep* = proc(core: string): CoreResult[bool] {.closure.}
  UnitStep* = proc(core, unit: string): CoreResult[bool] {.closure.}
  UnitsStep* = proc(core: string): CoreResult[seq[UnitSnapshot]] {.closure.}
  NoticeStep* = proc(core, message: string) {.closure.}
  ReadyQuery* = proc(): bool {.closure.}

  DiscoveredCore* = object
    ## What step 2 learned afresh from disk (§8). serviceHandler has no
    ## manifest: `metadata` stays empty and `extension` is false.
    metadata*: ManifestMetadata
    delegatesTo*: seq[string]
    activation*: ActivationStrategy
    hasUnitSubsystem*: bool
    extension*: bool
    hasSupervisor*: bool
    hasPersistentAdapters*: bool
  DiscoverStep* = proc(core: string): CoreResult[DiscoveredCore] {.closure.}

  LoadCallbacks* = object
    discoverValidate*: DiscoverStep   ## step 2
    resolveOperations*: BoolStep      ## step 4, incl. the E_CGROUP check for extensions
    createCgroup*: BoolStep           ## step 5 (§15.1 rule 1, delegation rule 4)
    createRuntimeDir*: BoolStep       ## step 5 (§19.1)
    filesystemsReady*: ReadyQuery     ## §20.2 "filesystems ready"
    createStateDir*: BoolStep         ## step 5, only once filesystems are ready
    runInit*: BoolStep                ## step 6 (60 s, unsandboxed, as account)
    startSupervisor*: BoolStep        ## step 7, called only if declared
    startAdapters*: BoolStep          ## step 8, called only if declared
    publish*: BoolStep                ## step 9
    seedNameIndex*: BoolStep          ## step 9, cores claiming `unit`
    scheduleActivation*: BoolStep     ## step 10 (asynchronous)
    stopAdapters*: BoolStep           ## rollback
    stopSupervisor*: BoolStep         ## rollback
    runShutdown*: BoolStep            ## rollback (60 s) if init completed
    killCgroup*: BoolStep             ## rollback: kill and remove subtree
    removeRuntimeDir*: BoolStep       ## rollback
    log*: NoticeStep

  UnloadCallbacks* = object
    close*: BoolStep                  ## step 1: new requests get E_CORE_STATE
    cancelStreams*: BoolStep          ## step 1: streams cancelled immediately
    deactivateCore*: BoolStep         ## step 2, activation "core"
    stopUnit*: UnitStep               ## step 2, activation "per-unit"
    reopen*: BoolStep                 ## step 2 failure
    drain*: BoolStep                  ## step 3 (own deadlines, <= 90 s total)
    runShutdown*: BoolStep            ## step 4 (60 s)
    stopAdapters*: BoolStep           ## step 5
    stopSupervisor*: BoolStep         ## step 5
    killCgroup*: BoolStep             ## step 6
    removeRuntimeDir*: BoolStep       ## step 7
    log*: NoticeStep

  ActivationCallbacks* = object
    listUnits*: UnitsStep
    activateCore*, reachNativeTarget*: BoolStep
    startUnit*: UnitStep
    notice*: NoticeStep

  ActivationFailure* = object
    unit*: string
    error*: CoreError

  ActivationReport* = object
    attempted*, succeeded*: int
    failures*: seq[ActivationFailure]

const
  DrainLimitSeconds* = 90
  InitTimeoutSeconds* = 60
  ShutdownTimeoutSeconds* = 60

proc newLoadCallbacks*(discoverValidate: DiscoverStep;
                       resolveOperations, createCgroup, createRuntimeDir: BoolStep;
                       filesystemsReady: ReadyQuery; createStateDir: BoolStep;
                       runInit, startSupervisor, startAdapters, publish,
                       seedNameIndex, scheduleActivation: BoolStep;
                       stopAdapters, stopSupervisor, runShutdown, killCgroup,
                       removeRuntimeDir: BoolStep;
                       log: NoticeStep): LoadCallbacks =
  LoadCallbacks(discoverValidate: discoverValidate,
    resolveOperations: resolveOperations, createCgroup: createCgroup,
    createRuntimeDir: createRuntimeDir, filesystemsReady: filesystemsReady,
    createStateDir: createStateDir, runInit: runInit,
    startSupervisor: startSupervisor, startAdapters: startAdapters,
    publish: publish, seedNameIndex: seedNameIndex,
    scheduleActivation: scheduleActivation, stopAdapters: stopAdapters,
    stopSupervisor: stopSupervisor, runShutdown: runShutdown,
    killCgroup: killCgroup, removeRuntimeDir: removeRuntimeDir, log: log)

proc newUnloadCallbacks*(close, cancelStreams, deactivateCore: BoolStep;
                         stopUnit: UnitStep;
                         reopen, drain, runShutdown, stopAdapters,
                         stopSupervisor, killCgroup, removeRuntimeDir: BoolStep;
                         log: NoticeStep): UnloadCallbacks =
  UnloadCallbacks(close: close, cancelStreams: cancelStreams,
    deactivateCore: deactivateCore, stopUnit: stopUnit, reopen: reopen,
    drain: drain, runShutdown: runShutdown, stopAdapters: stopAdapters,
    stopSupervisor: stopSupervisor, killCgroup: killCgroup,
    removeRuntimeDir: removeRuntimeDir, log: log)

proc newActivationCallbacks*(listUnits: UnitsStep;
                             activateCore, reachNativeTarget: BoolStep;
                             startUnit: UnitStep;
                             notice: NoticeStep): ActivationCallbacks =
  ActivationCallbacks(listUnits: listUnits, activateCore: activateCore,
    reachNativeTarget: reachNativeTarget, startUnit: startUnit, notice: notice)

proc missingCallbacks*(callbacks: LoadCallbacks): seq[string] =
  for name, value in callbacks.fieldPairs:
    if value.isNil: result.add name

proc missingCallbacks*(callbacks: UnloadCallbacks): seq[string] =
  for name, value in callbacks.fieldPairs:
    if value.isNil: result.add name

proc missingCallbacks*(callbacks: ActivationCallbacks): seq[string] =
  for name, value in callbacks.fieldPairs:
    if value.isNil: result.add name

proc internalError(kind: string; missing: seq[string]): CoreResult[bool] =
  failure[bool](ecBackend, "internal error: " & kind &
    " callbacks missing: " & missing.join(", "))

proc guarded(step: BoolStep; core: string): CoreResult[bool] =
  ## A raising callback is a failed step, never an escaped exception.
  try: step(core)
  except CoreError as e:
    failure[bool](e.code, e.msg, e.cores)
  except CatchableError as e:
    failure[bool](ecBackend, e.msg)

proc guardedUnit(step: UnitStep; core, unit: string): CoreResult[bool] =
  try: step(core, unit)
  except CoreError as e:
    failure[bool](e.code, e.msg, e.cores)
  except CatchableError as e:
    failure[bool](ecBackend, e.msg)

proc safeLog(log: NoticeStep; core, message: string) =
  try: log(core, message)
  except CatchableError: discard

proc asInit(outcome: CoreResult[bool]): CoreResult[bool] =
  ## Steps 6 to 8 report E_INIT (§20.3), keeping the underlying message.
  if outcome.ok or outcome.error.code == ecInit: outcome
  else: failure[bool](ecInit, outcome.error.message, outcome.error.cores)

proc executeLoad*(registry: var LifecycleRegistry; name: string;
                  callbacks: LoadCallbacks): CoreResult[bool] =
  ## Executes §20.3 in order. Any failure of steps 2 to 9 rolls completed work
  ## back in reverse (adapters, supervisor, shutdown if init completed, cgroup
  ## kill+remove, runtime directory) and leaves the core `failed` with its
  ## error. Cleanup errors are logged and secondary to the load error. The
  ## persistent state directory is left in place.
  let missing = callbacks.missingCallbacks
  if missing.len > 0: return internalError("load", missing)
  let begun = registry.startLoad(name)
  if not begun.ok: return begun
  if not begun.value: return success(false)
  let log = callbacks.log
  log.safeLog(name, "load started")

  var discovered: DiscoveredCore
  var cgroupDone, runtimeDone, initDone, supervisorDone, adaptersDone: bool
  var failed = success(true)

  template step(call: untyped; done: untyped) =
    if failed.ok:
      let current = call
      if current.ok: done = true
      else: failed = current

  # Step 2: discover and validate afresh.
  try:
    let snapshot = callbacks.discoverValidate(name)
    if snapshot.ok: discovered = snapshot.value
    else: failed = failure[bool](snapshot.error.code, snapshot.error.message,
                                 snapshot.error.cores)
  except CoreError as e: failed = failure[bool](e.code, e.msg, e.cores)
  except CatchableError as e: failed = failure[bool](ecManifest, e.msg)
  if failed.ok:
    discard registry.applyDefinition(name, discovered.delegatesTo,
      discovered.activation, discovered.hasUnitSubsystem)
    # Step 3: delegation targets, from the fresh definition.
    failed = registry.checkDelegationTargets(name)
  var ignored: bool
  step(guarded(callbacks.resolveOperations, name), ignored)   # step 4
  step(guarded(callbacks.createCgroup, name), cgroupDone)     # step 5
  step(guarded(callbacks.createRuntimeDir, name), runtimeDone)
  if failed.ok:
    var ready = false
    try: ready = callbacks.filesystemsReady()
    except CatchableError: ready = false
    if ready:
      let state = guarded(callbacks.createStateDir, name)
      if not state.ok:
        log.safeLog(name, "state directory not created (retried later): " &
          state.error.message)
  step(asInit(guarded(callbacks.runInit, name)), initDone)    # step 6
  if discovered.hasSupervisor:                                  # step 7
    step(asInit(guarded(callbacks.startSupervisor, name)), supervisorDone)
  if discovered.hasPersistentAdapters:                         # step 8
    step(asInit(guarded(callbacks.startAdapters, name)), adaptersDone)
  step(guarded(callbacks.publish, name), ignored)             # step 9

  if not failed.ok:
    log.safeLog(name, "load failed (" & errorName(failed.error.code) & "): " &
      failed.error.message & "; rolling back")
    template cleanup(done: bool; call: untyped; what: string) =
      if done:
        let undone = call
        if not undone.ok:
          log.safeLog(name, "rollback: " & what & " failed: " & undone.error.message)
    cleanup(adaptersDone, guarded(callbacks.stopAdapters, name), "stop adapters")
    cleanup(supervisorDone, guarded(callbacks.stopSupervisor, name), "stop supervisor")
    cleanup(initDone, guarded(callbacks.runShutdown, name), "shutdown")
    cleanup(cgroupDone, guarded(callbacks.killCgroup, name), "kill cgroup")
    cleanup(runtimeDone, guarded(callbacks.removeRuntimeDir, name), "remove runtime directory")
    discard registry.failLoad(name, errorName(failed.error.code) & ": " &
                              failed.error.message)
    return failed

  let completed = registry.completeLoad(name, discovered.metadata)
  if not completed.ok: return completed
  log.safeLog(name, "loaded")
  # Name-index seeding is best effort and activation is asynchronous;
  # neither may turn a published core into a failed core.
  if discovered.hasUnitSubsystem:
    let seeded = guarded(callbacks.seedNameIndex, name)
    if not seeded.ok:
      log.safeLog(name, "unit.list for the name index failed: " & seeded.error.message)
  let scheduled = guarded(callbacks.scheduleActivation, name)
  if not scheduled.ok:
    log.safeLog(name, "activation could not be scheduled: " & scheduled.error.message)
  success(true)

proc executeUnload*(registry: var LifecycleRegistry; name: string;
                    busy: BusySnapshot; callbacks: UnloadCallbacks;
                    options = UnloadOptions()): CoreResult[bool] =
  ## Executes §20.4. Close comes before stopping units and streams are
  ## cancelled immediately. A stop failure reopens the core in its previous
  ## state (loaded or degraded) and returns E_PARTIAL. Drain, shutdown and
  ## teardown failures are logged and the unload continues to `unloaded`.
  let missing = callbacks.missingCallbacks
  if missing.len > 0: return internalError("unload", missing)
  let before = registry.findCore(name)
  if before < 0: return failure[bool](ecManifest, "unknown core: " & name)
  let wasLive = registry.cores[before].state.isLoaded
  let planned = registry.beginUnload(name, busy, options)
  if not planned.ok:
    return failure[bool](planned.error.code, planned.error.message, planned.error.cores)
  if not wasLive: return success(false)
  let log = callbacks.log
  let previous = planned.value.previousState
  log.safeLog(name, "unload started")

  let closed = guarded(callbacks.close, name)
  if not closed.ok:
    discard registry.abortUnload(name, closed.error.message, previous)
    return failure[bool](ecPartial, closed.error.message, closed.error.cores)
  let cancelled = guarded(callbacks.cancelStreams, name)
  if not cancelled.ok:
    log.safeLog(name, "cancelling streams failed: " & cancelled.error.message)

  var stopped = success(true)
  if planned.value.degradedKillOnly:
    log.safeLog(name, "degraded core: its units will be ended by the cgroup kill")
  elif planned.value.deactivateCore:
    stopped = guarded(callbacks.deactivateCore, name)
  else:
    for unit in planned.value.stopUnits:
      let current = guardedUnit(callbacks.stopUnit, name, unit)
      if not current.ok:
        stopped = current
        break
  if not stopped.ok:
    let reopened = guarded(callbacks.reopen, name)
    if not reopened.ok:
      log.safeLog(name, "reopening after a failed stop failed: " & reopened.error.message)
    discard registry.abortUnload(name, stopped.error.message, previous)
    return failure[bool](ecPartial, stopped.error.message, stopped.error.cores)

  template teardown(call: untyped; what: string) =
    let current = call
    if not current.ok:
      log.safeLog(name, what & " failed: " & current.error.message)
  teardown(guarded(callbacks.drain, name), "drain")
  teardown(guarded(callbacks.runShutdown, name), "shutdown")
  teardown(guarded(callbacks.stopAdapters, name), "stop adapters")
  teardown(guarded(callbacks.stopSupervisor, name), "stop supervisor")
  teardown(guarded(callbacks.killCgroup, name), "kill cgroup")
  teardown(guarded(callbacks.removeRuntimeDir, name), "remove runtime directory")
  result = registry.completeUnload(name)
  if result.ok: log.safeLog(name, "unloaded")

proc executeReload*(registry: var LifecycleRegistry; name: string;
                    busy: BusySnapshot; loadCallbacks: LoadCallbacks;
                    unloadCallbacks: UnloadCallbacks;
                    options = UnloadOptions()): CoreResult[bool] =
  ## §20.5: unload then load with the same stop-units choice. Failed cores
  ## load directly; unloaded cores are not reloadable (E_CORE_STATE). If the
  ## load fails the core stays `failed`; nothing of the old version is kept.
  let pos = registry.findCore(name)
  if pos < 0: return failure[bool](ecManifest, "unknown core: " & name)
  case registry.cores[pos].state
  of csFailed: return registry.executeLoad(name, loadCallbacks)
  of csUnloaded: return failure[bool](ecCoreState, name & " is not loaded")
  of csLoading, csUnloading:
    return failure[bool](ecCoreState, name & " is changing lifecycle state")
  of csLoaded, csDegraded: discard
  let missing = loadCallbacks.missingCallbacks
  if missing.len > 0: return internalError("load", missing)
  let unloaded = registry.executeUnload(name, busy, unloadCallbacks, options)
  if not unloaded.ok: return unloaded
  registry.executeLoad(name, loadCallbacks)

proc executeActivation*(core: CoreRuntime;
                        callbacks: ActivationCallbacks): ActivationReport =
  ## §20.6. Activation failures are isolated and reported; they never alter
  ## core state or prevent later per-unit activations.
  if core.state != csLoaded or not core.hasUnitSubsystem: return
  let missing = callbacks.missingCallbacks
  if missing.len > 0:
    let message = "internal error: activation callbacks missing: " & missing.join(", ")
    result.failures.add ActivationFailure(error:
      CoreError(code: ecBackend, message: message, msg: message))
    return
  var units: seq[UnitSnapshot]
  if core.activation == asPerUnit:
    var listed: CoreResult[seq[UnitSnapshot]]
    try: listed = callbacks.listUnits(core.name)
    except CatchableError as e:
      listed = failure[seq[UnitSnapshot]](ecBackend, e.msg)
    if not listed.ok:
      result.failures.add ActivationFailure(error: listed.error)
      safeLog(callbacks.notice, core.name, "activation: unit.list failed: " &
        listed.error.message)
      return
    units = listed.value
  for action in activationPlan(core, units):
    inc result.attempted
    let outcome = case action.kind
      of aaActivateCore: guarded(callbacks.activateCore, core.name)
      of aaReachNativeTarget: guarded(callbacks.reachNativeTarget, core.name)
      of aaStartUnit: guardedUnit(callbacks.startUnit, core.name, action.unit)
    if outcome.ok:
      inc result.succeeded
      safeLog(callbacks.notice, core.name, "activation: " &
        (if action.unit.len > 0: action.unit & " started" else: "done"))
    else:
      result.failures.add ActivationFailure(unit: action.unit,
                                             error: outcome.error)
      safeLog(callbacks.notice, core.name, "activation" &
        (if action.unit.len > 0: " of " & action.unit else: "") & " failed: " &
        outcome.error.message)
