import std/unittest
import ../../jumpstart/cores/lifecycle/lifecycle

proc core(name: string; state = csUnloaded; delegates: seq[string] = @[];
          activation = asNone; units = false): CoreRuntime =
  CoreRuntime(name: name, state: state, delegatesTo: delegates,
              activation: activation, hasUnitSubsystem: units)

const UnitOptionsForTest = UnloadOptions(stopUnits: true)

suite "pure core lifecycle":
  test "load checks delegation targets and records the loaded snapshot":
    var r = LifecycleRegistry(cores: @[
      core("target", csUnloaded), core("client", delegates = @["target"])])
    let refused = r.beginLoad("client")
    check not refused.ok
    check refused.error.code == ecDelegation
    check r.cores[1].state == csUnloaded
    check r.beginLoad("target").ok
    check r.completeLoad("target", ManifestMetadata(size: 4, mtime: 1,
      sha256: sha256Hex("init"))).ok
    check r.beginLoad("client").ok
    check r.cores[1].state == csLoading
    check r.completeLoad("client", ManifestMetadata(size: 1, mtime: 2)).ok
    check r.cores[1].state == csLoaded

  test "failed loads retain diagnostics and can be loaded again":
    var r = LifecycleRegistry(cores: @[core("broken")])
    check r.beginLoad("broken").ok
    check r.failLoad("broken", "bad manifest").ok
    check r.cores[0].state == csFailed
    check r.cores[0].failure == "bad manifest"
    check r.beginLoad("broken").ok

  test "loading and unloading guards are state errors":
    var r = LifecycleRegistry(cores: @[core("a", csLoading)])
    check r.beginLoad("a").error.code == ecCoreState
    r.cores[0].state = csUnloading
    check r.beginUnload("a", BusySnapshot()).error.code == ecCoreState

  test "stable delegation order puts targets first and rejects cycles":
    let r = LifecycleRegistry(cores: @[
      core("unrelated"), core("client", delegates = @["target"]), core("target")])
    let order = r.delegationOrder(["unrelated", "client", "target"])
    check order.ok
    check order.value == @["unrelated", "target", "client"]
    let cyclic = LifecycleRegistry(cores: @[
      core("a", delegates = @["b"]), core("b", delegates = @["a"])])
    let bad = cyclic.delegationOrder(["a", "b"])
    check not bad.ok
    check bad.error.code == ecDelegation

  test "delegation order rejects chains longer than four hops":
    let r = LifecycleRegistry(cores: @[
      core("a", delegates = @["b"]), core("b", delegates = @["c"]),
      core("c", delegates = @["d"]), core("d", delegates = @["e"]),
      core("e", delegates = @["f"]), core("f")])
    let bad = r.delegationOrder(["a", "b", "c", "d", "e", "f"])
    check not bad.ok
    check bad.error.code == ecDelegation

  test "unload protects delegation targets before changing state":
    var r = LifecycleRegistry(cores: @[
      core("target", csLoaded), core("client", csLoaded, @["target"])])
    let refused = r.beginUnload("target", BusySnapshot())
    check refused.error.code == ecDelegation
    check refused.error.cores == @["client"]
    check r.cores[0].state == csLoaded

  test "only loaded core is protected except at daemon shutdown":
    var r = LifecycleRegistry(cores: @[core("native", csLoaded)])
    check r.beginUnload("native", BusySnapshot()).error.code == ecCoreState
    let allowed = r.beginUnload("native", BusySnapshot(),
      UnloadOptions(daemonShutdown: true))
    check allowed.ok
    check r.cores[0].state == csUnloading

  test "busy combines cgroup and status and stop order is reversed":
    let units = @[
      UnitSnapshot(name: "one", state: ursActive),
      UnitSnapshot(name: "two", state: ursInactive),
      UnitSnapshot(name: "three", state: ursActivating)]
    var r = LifecycleRegistry(cores: @[
      core("native", csLoaded), core("ext", csLoaded, activation = asPerUnit)])
    let refused = r.beginUnload("ext", BusySnapshot(units: units))
    check refused.error.code == ecBusy
    check refused.error.cores == @["one", "three"]
    let plan = r.beginUnload("ext", BusySnapshot(units: units),
      UnloadOptions(stopUnits: true))
    check plan.ok
    check plan.value.stopUnits == @["three", "one"]
    check r.cores[1].state == csUnloading

  test "active mount and swap units do not make a core busy (§20.4, §12.2)":
    var r = LifecycleRegistry(cores: @[
      core("native", csLoaded), core("ext", csLoaded, activation = asCore)])
    let kernel = @[
      UnitSnapshot(name: "-.mount", subsystem: "mount", state: ursActive),
      UnitSnapshot(name: "dev-sda2.swap", subsystem: "swap", state: ursActive),
      UnitSnapshot(name: "tmp.mount", subsystem: "mount", state: ursInactive)]
    check not BusySnapshot(units: kernel).isBusy
    check activeUnits(BusySnapshot(units: kernel)).len == 0
    let plan = r.beginUnload("ext", BusySnapshot(units: kernel))
    check plan.ok
    r.cores[1].state = csLoaded
    # A service still makes the core busy, and only it is named.
    let mixed = kernel & @[UnitSnapshot(name: "sshd.service", subsystem: "service",
      state: ursActive)]
    let refused = r.beginUnload("ext", BusySnapshot(units: mixed))
    check refused.error.code == ecBusy
    check refused.error.cores == @["sshd.service"]
    # Other kinds of kernel-state-like subsystems do not get the exemption.
    for subsystem in ["service", "timer", "socket", "target", "path", "device", ""]:
      check BusySnapshot(units: @[UnitSnapshot(name: "u", subsystem: subsystem,
        state: ursActive)]).isBusy
    # A mount or swap that is transitioning still counts.
    for state in [ursActivating, ursDeactivating, ursReloading]:
      for subsystem in ["mount", "swap"]:
        check BusySnapshot(units: @[UnitSnapshot(name: "u", subsystem: subsystem,
          state: state)]).isBusy
    # The cgroup check is independent of the exemption.
    check BusySnapshot(cgroupAvailable: true, cgroupPopulated: true,
      units: kernel).isBusy

  test "reloading counts as busy for every subsystem (§12.11)":
    for subsystem in ["service", "mount", "swap", "target", ""]:
      check BusySnapshot(units: @[UnitSnapshot(name: "u", subsystem: subsystem,
        state: ursReloading)]).isBusy
    var r = LifecycleRegistry(cores: @[
      core("native", csLoaded), core("ext", csLoaded, activation = asPerUnit)])
    let units = @[
      UnitSnapshot(name: "a.service", subsystem: "service", state: ursReloading),
      UnitSnapshot(name: "-.mount", subsystem: "mount", state: ursActive),
      UnitSnapshot(name: "b.service", subsystem: "service", state: ursActive)]
    let plan = r.beginUnload("ext", BusySnapshot(units: units),
      UnitOptionsForTest)
    check plan.ok
    # Per-unit stopping skips the active mount, like the busy check, and keeps
    # the reverse list order.
    check plan.value.stopUnits == @["b.service", "a.service"]

  test "degraded busy checks ignore status but honor cgroup":
    var r = LifecycleRegistry(cores: @[
      core("native", csLoaded), core("ext", csDegraded)])
    let statusOnly = BusySnapshot(units: @[
      UnitSnapshot(name: "old", state: ursActive)])
    check r.beginUnload("ext", statusOnly).ok
    r.cores[1].state = csDegraded
    let populated = BusySnapshot(cgroupAvailable: true, cgroupPopulated: true)
    check r.beginUnload("ext", populated).error.code == ecBusy
    let plan = r.beginUnload("ext", populated, UnloadOptions(stopUnits: true))
    check plan.ok
    check plan.value.degradedKillOnly

  test "failed stop reopens core and successful unload completes":
    var r = LifecycleRegistry(cores: @[
      core("native", csLoaded), core("ext", csLoaded)])
    check r.beginUnload("ext", BusySnapshot()).ok
    let failed = r.abortUnload("ext", "stop failed")
    check failed.error.code == ecPartial
    check r.cores[1].state == csLoaded
    check r.beginUnload("ext", BusySnapshot()).ok
    check r.completeUnload("ext").ok
    check r.cores[1].state == csUnloaded

  test "reload uses unload guards and failed cores load directly":
    var r = LifecycleRegistry(cores: @[
      core("native", csLoaded), core("ext", csLoaded)])
    let guarded = r.beginReload("ext", BusySnapshot(cgroupAvailable: true,
      cgroupPopulated: true))
    check guarded.error.code == ecBusy
    check r.cores[1].state == csLoaded
    r.cores[1].state = csFailed
    let direct = r.beginReload("ext", BusySnapshot())
    check direct.ok
    check direct.value.kind == rpLoadOnly
    check r.cores[1].state == csLoading

  test "load order requires delegation targets in the requested set":
    let r = LifecycleRegistry(cores: @[
      core("client", delegates = @["target"]), core("target")])
    let bad = r.delegationOrder(["client"])
    check not bad.ok
    check bad.error.code == ecDelegation

  test "metadata detects size mtime and digest changes":
    let a = ManifestMetadata(size: 3, mtime: 7, sha256: sha256Hex("abc"))
    check not isStale(a, a)
    check isStale(a, ManifestMetadata(size: 4, mtime: 7, sha256: a.sha256))
    check isStale(a, ManifestMetadata(size: 3, mtime: 8, sha256: a.sha256))
    check isStale(a, ManifestMetadata(size: 3, mtime: 7, sha256: sha256Hex("abd")))
    check sha256Hex("abc") ==
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

  test "activation plans are declarative and preserve list order":
    let units = @[
      UnitSnapshot(name: "a", enabled: true),
      UnitSnapshot(name: "b", enabled: false),
      UnitSnapshot(name: "c", enabled: true)]
    let per = activationPlan(core("x", csLoaded, activation = asPerUnit,
                                  units = true), units)
    check per.len == 2
    check per[0].kind == aaStartUnit
    check per[0].unit == "a"
    check per[1].unit == "c"
    let whole = activationPlan(core("x", csLoaded, activation = asCore,
                                    units = true), units)
    check whole.len == 1
    check whole[0].kind == aaActivateCore
    check activationPlan(core("x", csDegraded, activation = asCore,
                              units = true), units).len == 0

  test "routing follows each runtime state":
    check routingError(core("x", csLoaded)).ok
    check routingError(core("x", csUnloaded)).error.code == ecCoreUnloaded
    check routingError(core("x", csFailed)).error.code == ecCoreFailed
    check routingError(core("x", csDegraded)).error.code == ecDegraded
    check routingError(core("x", csUnloading)).error.code == ecCoreState

# Executor (§20.3-§20.6) ------------------------------------------------------
import std/[os, strutils, times]
import ../../jumpstart/cores/lifecycle/lifecycle_exec

type Recorder = ref object
  calls: seq[string]
  logs: seq[string]
  failAt: string
  discovered: DiscoveredCore
  ready: bool

proc step(rec: Recorder; name: string): BoolStep =
  result = proc(core: string): CoreResult[bool] =
    rec.calls.add name
    if rec.failAt == name: failure[bool](ecBackend, name & " failed")
    else: success(true)

proc loadCallbacks(rec: Recorder): LoadCallbacks =
  newLoadCallbacks(
    discoverValidate = proc(core: string): CoreResult[DiscoveredCore] =
      rec.calls.add "discover"
      if rec.failAt == "discover": failure[DiscoveredCore](ecManifest, "bad manifest")
      else: success(rec.discovered),
    resolveOperations = rec.step("resolve"),
    createCgroup = rec.step("cgroup"),
    createRuntimeDir = rec.step("runtime"),
    filesystemsReady = proc(): bool = rec.ready,
    createStateDir = rec.step("state"),
    runInit = rec.step("init"),
    startSupervisor = rec.step("supervisor"),
    startAdapters = rec.step("adapters"),
    publish = rec.step("publish"),
    seedNameIndex = rec.step("seed"),
    scheduleActivation = rec.step("activate"),
    stopAdapters = rec.step("undo-adapters"),
    stopSupervisor = rec.step("undo-supervisor"),
    runShutdown = rec.step("undo-shutdown"),
    killCgroup = rec.step("undo-cgroup"),
    removeRuntimeDir = rec.step("undo-runtime"),
    log = proc(core, message: string) = rec.logs.add message)

proc unloadCallbacks(rec: Recorder): UnloadCallbacks =
  newUnloadCallbacks(
    close = rec.step("close"), cancelStreams = rec.step("cancel-streams"),
    deactivateCore = rec.step("deactivate"),
    stopUnit = proc(core, unit: string): CoreResult[bool] =
      rec.calls.add "stop:" & unit
      if rec.failAt == "stop:" & unit: failure[bool](ecBackend, "stop failed")
      else: success(true),
    reopen = rec.step("reopen"), drain = rec.step("drain"),
    runShutdown = rec.step("shutdown"), stopAdapters = rec.step("stop-adapters"),
    stopSupervisor = rec.step("stop-supervisor"), killCgroup = rec.step("kill-cgroup"),
    removeRuntimeDir = rec.step("remove-runtime"),
    log = proc(core, message: string) = rec.logs.add message)

proc fullCore(): DiscoveredCore =
  DiscoveredCore(metadata: ManifestMetadata(size: 1, mtime: 2, sha256: "ab"),
    activation: asPerUnit, hasUnitSubsystem: true, extension: true,
    hasSupervisor: true, hasPersistentAdapters: true)

suite "lifecycle executor":
  test "every callback is required and a missing one changes nothing":
    var r = LifecycleRegistry(cores: @[core("ext")])
    var callbacks = loadCallbacks(Recorder(discovered: fullCore()))
    callbacks.createStateDir = nil
    let refused = r.executeLoad("ext", callbacks)
    check not refused.ok
    check "createStateDir" in refused.error.message
    check r.cores[0].state == csUnloaded
    var unload = unloadCallbacks(Recorder())
    unload.stopUnit = nil
    r.cores[0].state = csLoaded
    r.cores.add core("other", csLoaded)
    check not r.executeUnload("ext", BusySnapshot(), unload).ok
    check r.cores[0].state == csLoaded
    let report = executeActivation(core("ext", csLoaded, activation = asCore, units = true),
                                   ActivationCallbacks())
    check report.failures.len == 1
    check report.succeeded == 0

  test "load runs every §20.3 step in order and records the manifest snapshot":
    let rec = Recorder(discovered: fullCore(), ready: true)
    var r = LifecycleRegistry(cores: @[core("ext")])
    check r.executeLoad("ext", loadCallbacks(rec)).ok
    check rec.calls == @["discover", "resolve", "cgroup", "runtime", "state", "init",
      "supervisor", "adapters", "publish", "seed", "activate"]
    check r.cores[0].state == csLoaded
    check r.cores[0].loadedManifest == fullCore().metadata
    check r.cores[0].activation == asPerUnit

  test "the state directory waits for filesystems and its failure is only logged":
    let rec = Recorder(discovered: fullCore(), ready: false)
    var r = LifecycleRegistry(cores: @[core("ext")])
    check r.executeLoad("ext", loadCallbacks(rec)).ok
    check "state" notin rec.calls
    let failing = Recorder(discovered: fullCore(), ready: true, failAt: "state")
    var r2 = LifecycleRegistry(cores: @[core("ext")])
    check r2.executeLoad("ext", loadCallbacks(failing)).ok
    check r2.cores[0].state == csLoaded
    check failing.logs.join("\n").contains("state directory not created")

  test "load re-discovers before checking delegation targets":
    var discovered = fullCore()
    discovered.delegatesTo = @["target"]
    let rec = Recorder(discovered: discovered)
    var r = LifecycleRegistry(cores: @[core("target"), core("client")])
    let refused = r.executeLoad("client", loadCallbacks(rec))
    check refused.error.code == ecDelegation
    check rec.calls == @["discover"]           # discovery came first
    check r.cores[1].state == csFailed
    check r.cores[1].delegatesTo == @["target"]

  test "a core whose definition fails becomes failed and keeps its error":
    let rec = Recorder(failAt: "discover")
    var r = LifecycleRegistry()
    let failed = r.executeLoad("newcore", loadCallbacks(rec))
    check failed.error.code == ecManifest
    check r.findCore("newcore") >= 0
    check r.cores[r.findCore("newcore")].state == csFailed
    check "bad manifest" in r.cores[r.findCore("newcore")].failure
    check r.markFailed("missing", "E_NOT_FOUND: not installed").ok
    check r.cores[r.findCore("missing")].state == csFailed
    r.cores.add core("live", csLoaded)
    check not r.markFailed("live", "x").ok
    check r.cores[r.findCore("live")].state == csLoaded

  test "a failed load at any step rolls back fully in reverse":
    let expectations = [
      ("resolve", newSeq[string]()),
      ("cgroup", newSeq[string]()),
      ("runtime", @["undo-cgroup"]),
      ("init", @["undo-cgroup", "undo-runtime"]),
      ("supervisor", @["undo-shutdown", "undo-cgroup", "undo-runtime"]),
      ("adapters", @["undo-supervisor", "undo-shutdown", "undo-cgroup", "undo-runtime"]),
      ("publish", @["undo-adapters", "undo-supervisor", "undo-shutdown",
                    "undo-cgroup", "undo-runtime"])]
    for (failAt, undo) in expectations:
      let rec = Recorder(discovered: fullCore(), failAt: failAt)
      var r = LifecycleRegistry(cores: @[core("ext")])
      let failed = r.executeLoad("ext", loadCallbacks(rec))
      check not failed.ok
      if failAt in ["init", "supervisor", "adapters"]:
        check failed.error.code == ecInit
      var rollback: seq[string]
      for call in rec.calls:
        if call.startsWith("undo-"): rollback.add call
      check rollback == undo
      check r.cores[0].state == csFailed
      check "seed" notin rec.calls and "activate" notin rec.calls

  test "cores without supervisors or adapters skip those steps explicitly":
    var discovered = fullCore()
    discovered.hasSupervisor = false
    discovered.hasPersistentAdapters = false
    discovered.hasUnitSubsystem = false
    let rec = Recorder(discovered: discovered)
    var r = LifecycleRegistry(cores: @[core("ext")])
    check r.executeLoad("ext", loadCallbacks(rec)).ok
    check rec.calls == @["discover", "resolve", "cgroup", "runtime", "init",
                         "publish", "activate"]

  test "name index and activation failures never fail a published core":
    for failAt in ["seed", "activate"]:
      let rec = Recorder(discovered: fullCore(), failAt: failAt)
      var r = LifecycleRegistry(cores: @[core("ext")])
      check r.executeLoad("ext", loadCallbacks(rec)).ok
      check r.cores[0].state == csLoaded

  test "unload closes before stopping, cancels streams immediately and tears down in order":
    let rec = Recorder()
    var r = LifecycleRegistry(cores: @[core("native", csLoaded),
      core("ext", csLoaded, activation = asPerUnit)])
    let busy = BusySnapshot(units: @[UnitSnapshot(name: "a", state: ursActive),
                                     UnitSnapshot(name: "b", state: ursActive)])
    check r.executeUnload("ext", busy, unloadCallbacks(rec),
                          UnloadOptions(stopUnits: true)).ok
    check rec.calls == @["close", "cancel-streams", "stop:b", "stop:a", "drain",
      "shutdown", "stop-adapters", "stop-supervisor", "kill-cgroup", "remove-runtime"]
    check r.cores[1].state == csUnloaded

  test "a failed stop reopens the core in its previous state with E_PARTIAL":
    let rec = Recorder(failAt: "stop:a")
    var r = LifecycleRegistry(cores: @[core("native", csLoaded),
      core("ext", csLoaded, activation = asPerUnit)])
    let busy = BusySnapshot(units: @[UnitSnapshot(name: "a", state: ursActive)])
    let failed = r.executeUnload("ext", busy, unloadCallbacks(rec),
                                 UnloadOptions(stopUnits: true))
    check failed.error.code == ecPartial
    check rec.calls == @["close", "cancel-streams", "stop:a", "reopen"]
    check r.cores[1].state == csLoaded
    check r.cores[1].failure == ""

  test "an aborted unload of a degraded core leaves it degraded":
    var r = LifecycleRegistry(cores: @[core("native", csLoaded), core("ext", csLoaded)])
    check r.markDegraded("ext", "supervisor exited").ok
    let plan = r.beginUnload("ext", BusySnapshot())
    check plan.value.previousState == csDegraded
    discard r.abortUnload("ext", "close failed")
    check r.cores[1].state == csDegraded
    check r.cores[1].failure == "supervisor exited"
    check r.beginUnload("ext", BusySnapshot()).ok
    discard r.abortUnload("ext", "again", csDegraded)
    check r.cores[1].state == csDegraded

  test "a degraded core skips stopping units; the cgroup kill ends them":
    let rec = Recorder()
    var r = LifecycleRegistry(cores: @[core("native", csLoaded),
      core("ext", csDegraded, activation = asCore)])
    r.cores[1].failure = "adapter restart budget exceeded"
    let busy = BusySnapshot(cgroupAvailable: true, cgroupPopulated: true)
    check not r.executeUnload("ext", busy, unloadCallbacks(rec)).ok   # E_BUSY
    check rec.calls.len == 0
    check r.executeUnload("ext", busy, unloadCallbacks(rec),
                          UnloadOptions(stopUnits: true)).ok
    check "deactivate" notin rec.calls
    check "kill-cgroup" in rec.calls
    check rec.logs.join("\n").contains("ended by the cgroup kill")

  test "reload picks up changed files and clears staleness":
    let dir = getTempDir() / ("jumpstart-reload-" & $getCurrentProcessId())
    createDir(dir)
    defer: removeDir(dir)
    let manifest = dir / "init.kg"
    writeFile(manifest, "manifest_version: 1\n")
    var r = LifecycleRegistry(cores: @[core("native", csLoaded), core("ext")])
    let rec = Recorder()
    var load = loadCallbacks(rec)
    load.discoverValidate = proc(core: string): CoreResult[DiscoveredCore] =
      var d = fullCore()
      d.metadata = manifestMetadata(manifest)
      success(d)
    check r.executeLoad("ext", load).ok
    check not coreStale(r.cores[1], manifestMetadata(manifest))
    writeFile(manifest, "manifest_version: 1\nchanged: true\n")
    setLastModificationTime(manifest, getTime() + initDuration(seconds = 5))
    check coreStale(r.cores[1], manifestMetadata(manifest))
    check r.executeReload("ext", BusySnapshot(), load, unloadCallbacks(rec)).ok
    check r.cores[1].state == csLoaded
    check not coreStale(r.cores[1], manifestMetadata(manifest))
    check coreStale(r.cores[1], ManifestMetadata(), diskAvailable = false)

  test "reload leaves the core failed when the new version is invalid":
    var r = LifecycleRegistry(cores: @[core("native", csLoaded), core("ext", csLoaded)])
    let rec = Recorder(failAt: "discover")
    let reloaded = r.executeReload("ext", BusySnapshot(), loadCallbacks(rec),
                                   unloadCallbacks(rec))
    check not reloaded.ok
    check r.cores[1].state == csFailed
    check r.cores[1].loadedManifest == ManifestMetadata()

  test "activation runs by strategy, isolates failures and never changes state":
    var started: seq[string]
    let callbacks = newActivationCallbacks(
      listUnits = proc(core: string): CoreResult[seq[UnitSnapshot]] =
        success(@[UnitSnapshot(name: "a", enabled: true),
                  UnitSnapshot(name: "b", enabled: false),
                  UnitSnapshot(name: "c", enabled: true)]),
      activateCore = proc(core: string): CoreResult[bool] = success(true),
      reachNativeTarget = proc(core: string): CoreResult[bool] = success(true),
      startUnit = proc(core, unit: string): CoreResult[bool] =
        started.add unit
        if unit == "a": failure[bool](ecBackend, "boom") else: success(true),
      notice = proc(core, message: string) = discard)
    let c = core("ext", csLoaded, activation = asPerUnit, units = true)
    let report = executeActivation(c, callbacks)
    check started == @["a", "c"]
    check report.attempted == 2 and report.succeeded == 1
    check report.failures[0].unit == "a"
