## Pure, deterministic core lifecycle state machine (§20).
## No dispatch, cgroup operation, or process launch occurs. The only
## filesystem access is `manifestMetadata`, which reads an init.kg for the
## staleness check of §20.1.
import std/[bitops, os, sequtils, strutils, times]
import ../manifest/types
import jumpstartcore/errors
export errors, types

type
  UnloadPlan* = object
    stopUnits*: seq[string]
    deactivateCore*: bool
    degradedKillOnly*: bool
    previousState*: CoreState
      ## csLoaded or csDegraded: the state an aborted unload restores.

  ReloadPlanKind* = enum
    rpLoadOnly, rpUnloadThenLoad

  ReloadPlan* = object
    kind*: ReloadPlanKind
    unload*: UnloadPlan

proc findCore*(registry: LifecycleRegistry; name: string): int =
  for i, core in registry.cores:
    if core.name == name: return i
  -1

proc isLoaded*(state: CoreState): bool {.inline.} =
  state in {csLoaded, csDegraded}

proc loadedCount*(registry: LifecycleRegistry): int =
  for core in registry.cores:
    if core.state.isLoaded: inc result

const KernelStateSubsystems* = ["mount", "swap"]
  ## §20.4 precondition 4: units of these subsystems represent kernel state; a
  ## core MAY leave them `active` after `unit.deactivate` (§12.2).

proc blocksUnload*(unit: UnitSnapshot): bool =
  ## §20.4 precondition 4: a unit makes its core busy when it is `active`,
  ## `activating`, `deactivating`, or `reloading`, except that a `mount` or
  ## `swap` unit that is plainly `active` is ignored. A mount or swap that is
  ## transitioning (`activating`, `deactivating`, `reloading`) still counts.
  case unit.state
  of ursActive: unit.subsystem notin KernelStateSubsystems
  of ursActivating, ursDeactivating, ursReloading: true
  of ursInactive, ursFailed: false

proc activeUnits*(busy: BusySnapshot; degraded = false): seq[string] =
  if not degraded:
    for unit in busy.units:
      if unit.blocksUnload: result.add unit.name

proc isBusy*(busy: BusySnapshot; degraded = false): bool =
  (busy.cgroupAvailable and busy.cgroupPopulated) or
    activeUnits(busy, degraded).len != 0

proc isStale*(loaded, disk: ManifestMetadata): bool =
  if loaded.size != disk.size or loaded.mtime != disk.mtime: return true
  loaded.sha256.len > 0 and disk.sha256.len > 0 and
    loaded.sha256.toLowerAscii != disk.sha256.toLowerAscii

proc coreStale*(core: CoreRuntime; disk: ManifestMetadata;
                diskAvailable = true): bool =
  ## §20.1: only a loaded (or degraded) core can be stale. A manifest that
  ## vanished from disk also differs from the one the core was loaded from.
  if not core.state.isLoaded: return false
  if core.loadedManifest == ManifestMetadata(): return false # serviceHandler
  if not diskAvailable: return true
  isStale(core.loadedManifest, disk)

proc routingError*(core: CoreRuntime): CoreResult[bool] =
  case core.state
  of csLoaded: success(true)
  of csUnloaded: failure[bool](ecCoreUnloaded, core.name & " is not loaded")
  of csFailed: failure[bool](ecCoreFailed, core.name & " failed to load")
  of csDegraded: failure[bool](ecDegraded, core.name & " is degraded")
  of csLoading, csUnloading:
    failure[bool](ecCoreState, core.name & " is changing lifecycle state")

proc ensureCore*(registry: var LifecycleRegistry; name: string): int =
  ## Index of `name`, adding it as `unloaded` when the registry lacks it.
  result = registry.findCore(name)
  if result < 0:
    registry.cores.add CoreRuntime(name: name, state: csUnloaded)
    result = registry.cores.high

proc markFailed*(registry: var LifecycleRegistry; name, reason: string): CoreResult[bool] =
  ## §20.2: a core that is missing or whose definition fails to load enters
  ## `failed` and keeps its error for `cores status`. A loaded or degraded
  ## core keeps running the version it was loaded from (it becomes stale), so
  ## it is not touched; neither is a core in transition.
  let pos = registry.ensureCore(name)
  case registry.cores[pos].state
  of csLoaded, csDegraded, csLoading, csUnloading:
    failure[bool](ecCoreState, name & " is " & ($registry.cores[pos].state)[2 .. ^1].toLowerAscii)
  of csUnloaded, csFailed:
    registry.cores[pos].state = csFailed
    registry.cores[pos].failure = if reason.len > 0: reason else: "load failed"
    success(true)

proc startLoad*(registry: var LifecycleRegistry; name: string): CoreResult[bool] =
  ## Step 1 of §20.3 only: loaded/degraded succeed without change (false),
  ## loading/unloading fail with E_CORE_STATE, anything else becomes
  ## `loading`. Delegation is checked only after the core was re-discovered
  ## (`applyDefinition` + `checkDelegationTargets`), because targets come from
  ## the fresh manifest. Unknown cores are added: discovery decides whether
  ## they exist.
  let pos = registry.ensureCore(name)
  let state = registry.cores[pos].state
  if state in {csLoaded, csDegraded}: return success(false)
  if state in {csLoading, csUnloading}:
    return failure[bool](ecCoreState, name & " is changing lifecycle state")
  registry.cores[pos].state = csLoading
  registry.cores[pos].failure = ""
  success(true)

proc applyDefinition*(registry: var LifecycleRegistry; name: string;
                      delegatesTo: seq[string]; activation: ActivationStrategy;
                      hasUnitSubsystem: bool): CoreResult[bool] =
  ## Record what step 2 discovered afresh for a loading core.
  let pos = registry.findCore(name)
  if pos < 0 or registry.cores[pos].state != csLoading:
    return failure[bool](ecCoreState, name & " is not loading")
  registry.cores[pos].delegatesTo = delegatesTo
  registry.cores[pos].activation = activation
  registry.cores[pos].hasUnitSubsystem = hasUnitSubsystem
  success(true)

proc checkDelegationTargets*(registry: LifecycleRegistry; name: string): CoreResult[bool] =
  ## Step 3 of §20.3: every delegation target must be loaded (or degraded).
  let pos = registry.findCore(name)
  if pos < 0: return failure[bool](ecManifest, "unknown core: " & name)
  var missing: seq[string]
  for target in registry.cores[pos].delegatesTo:
    let targetPos = registry.findCore(target)
    if targetPos < 0 or not registry.cores[targetPos].state.isLoaded:
      missing.add target
  if missing.len != 0:
    return failure[bool](ecDelegation,
      name & " requires loaded delegation target(s): " & missing.join(", "), missing)
  success(true)

proc beginLoad*(registry: var LifecycleRegistry; name: string): CoreResult[bool] =
  ## Legacy single-step entry used when the caller already holds a fresh
  ## definition: step 1 plus the delegation check against the recorded
  ## targets. The executor (lifecycle_exec) uses startLoad/applyDefinition/
  ## checkDelegationTargets to follow §20.3's order exactly.
  let pos = registry.findCore(name)
  if pos < 0: return failure[bool](ecManifest, "unknown core: " & name)
  let state = registry.cores[pos].state
  if state in {csLoaded, csDegraded}: return success(false)
  if state in {csLoading, csUnloading}:
    return failure[bool](ecCoreState, name & " is changing lifecycle state")
  let delegation = registry.checkDelegationTargets(name)
  if not delegation.ok: return delegation
  registry.cores[pos].state = csLoading
  registry.cores[pos].failure = ""
  success(true)

proc completeLoad*(registry: var LifecycleRegistry; name: string;
                   metadata: ManifestMetadata): CoreResult[bool] =
  ## Records the init.kg snapshot the core was loaded from; staleness is
  ## computed against it (§20.1) and a reload therefore clears staleness.
  let pos = registry.findCore(name)
  if pos < 0 or registry.cores[pos].state != csLoading:
    return failure[bool](ecCoreState, name & " is not loading")
  registry.cores[pos].state = csLoaded
  registry.cores[pos].loadedManifest = metadata
  registry.cores[pos].failure = ""
  success(true)

proc failLoad*(registry: var LifecycleRegistry; name, reason: string): CoreResult[bool] =
  let pos = registry.findCore(name)
  if pos < 0 or registry.cores[pos].state != csLoading:
    return failure[bool](ecCoreState, name & " is not loading")
  registry.cores[pos].state = csFailed
  registry.cores[pos].failure = if reason.len > 0: reason else: "load failed"
  registry.cores[pos].loadedManifest = ManifestMetadata()
  success(true)

proc markDegraded*(registry: var LifecycleRegistry; name, reason: string): CoreResult[bool] =
  ## A degraded core always carries a non-empty reason (also relied on by the
  ## two-argument abortUnload to restore `degraded`).
  let pos = registry.findCore(name)
  if pos < 0 or registry.cores[pos].state != csLoaded:
    return failure[bool](ecCoreState, name & " is not loaded")
  registry.cores[pos].state = csDegraded
  registry.cores[pos].failure = if reason.len > 0: reason else: "degraded"
  success(true)

proc beginUnload*(registry: var LifecycleRegistry; name: string;
                  busy: BusySnapshot; options = UnloadOptions()): CoreResult[UnloadPlan] =
  let pos = registry.findCore(name)
  if pos < 0: return failure[UnloadPlan](ecManifest, "unknown core: " & name)
  let state = registry.cores[pos].state
  if state in {csUnloaded, csFailed}: return success(UnloadPlan())
  if state in {csLoading, csUnloading}:
    return failure[UnloadPlan](ecCoreState, name & " is changing lifecycle state")
  var dependents: seq[string]
  for core in registry.cores:
    if core.name != name and core.state.isLoaded and name in core.delegatesTo:
      dependents.add core.name
  if dependents.len != 0:
    return failure[UnloadPlan](ecDelegation,
      name & " is required by loaded core(s): " & dependents.join(", "), dependents)
  if not options.daemonShutdown and registry.loadedCount == 1:
    return failure[UnloadPlan](ecCoreState, name & " is the only loaded core")
  let degraded = state == csDegraded
  let units = activeUnits(busy, degraded)
  if busy.isBusy(degraded) and not options.stopUnits:
    let detail = if units.len != 0: units.join(", ") else: "unit processes remain"
    return failure[UnloadPlan](ecBusy, name & " is busy: " & detail, units)
  result = success(UnloadPlan(previousState: state))
  if options.stopUnits:
    if degraded:
      result.value.degradedKillOnly = true
    elif registry.cores[pos].activation == asCore:
      result.value.deactivateCore = true
    elif registry.cores[pos].activation == asPerUnit:
      for i in countdown(busy.units.high, 0):
        if busy.units[i].blocksUnload:
          result.value.stopUnits.add busy.units[i].name
  registry.cores[pos].state = csUnloading

proc beginReload*(registry: var LifecycleRegistry; name: string;
                  busy: BusySnapshot;
                  options = UnloadOptions()): CoreResult[ReloadPlan] =
  ## A failed core reloads by loading directly. Loaded/degraded cores use the
  ## exact unload guards and plan first; completeUnload followed by beginLoad
  ## performs the two remaining state transitions.
  let pos = registry.findCore(name)
  if pos < 0: return failure[ReloadPlan](ecManifest, "unknown core: " & name)
  case registry.cores[pos].state
  of csFailed:
    let started = registry.beginLoad(name)
    if not started.ok:
      return failure[ReloadPlan](started.error.code, started.error.message,
                                 started.error.cores)
    success(ReloadPlan(kind: rpLoadOnly))
  of csLoaded, csDegraded:
    let plan = registry.beginUnload(name, busy, options)
    if not plan.ok:
      return failure[ReloadPlan](plan.error.code, plan.error.message,
                                 plan.error.cores)
    success(ReloadPlan(kind: rpUnloadThenLoad, unload: plan.value))
  of csUnloaded:
    failure[ReloadPlan](ecCoreState, name & " is not loaded")
  of csLoading, csUnloading:
    failure[ReloadPlan](ecCoreState, name & " is changing lifecycle state")

proc abortUnload*(registry: var LifecycleRegistry; name, reason: string;
                  restore: CoreState): CoreResult[bool] =
  ## §20.4 step 2 failure: the core reopens in the state it had before the
  ## unload began (`UnloadPlan.previousState`). A degraded core stays
  ## degraded with its original reason; the abort reason is the E_PARTIAL
  ## error returned to the caller.
  let pos = registry.findCore(name)
  if pos < 0 or registry.cores[pos].state != csUnloading:
    return failure[bool](ecCoreState, name & " is not unloading")
  if restore notin {csLoaded, csDegraded}:
    return failure[bool](ecCoreState, "an aborted unload restores loaded or degraded")
  registry.cores[pos].state = restore
  if restore == csLoaded: registry.cores[pos].failure = ""
  elif registry.cores[pos].failure.len == 0: registry.cores[pos].failure = "degraded"
  failure[bool](ecPartial, reason)

proc abortUnload*(registry: var LifecycleRegistry; name, reason: string): CoreResult[bool] =
  ## Compatibility form: a degraded core always has a non-empty `failure`
  ## (markDegraded, supervisor exit) while a loaded core has none, so the
  ## previous state is recoverable. Prefer passing UnloadPlan.previousState.
  let pos = registry.findCore(name)
  if pos < 0 or registry.cores[pos].state != csUnloading:
    return failure[bool](ecCoreState, name & " is not unloading")
  let restore = if registry.cores[pos].failure.len > 0: csDegraded else: csLoaded
  registry.abortUnload(name, reason, restore)

proc completeUnload*(registry: var LifecycleRegistry; name: string): CoreResult[bool] =
  let pos = registry.findCore(name)
  if pos < 0 or registry.cores[pos].state != csUnloading:
    return failure[bool](ecCoreState, name & " is not unloading")
  registry.cores[pos].state = csUnloaded
  registry.cores[pos].failure = ""
  success(true)

proc activationPlan*(core: CoreRuntime;
                     units: openArray[UnitSnapshot]): seq[ActivationAction] =
  if core.state != csLoaded or not core.hasUnitSubsystem: return
  case core.activation
  of asCore: result.add ActivationAction(kind: aaActivateCore)
  of asNative: result.add ActivationAction(kind: aaReachNativeTarget)
  of asPerUnit:
    for unit in units:
      if unit.enabled: result.add ActivationAction(kind: aaStartUnit, unit: unit.name)
  of asNone: discard

proc delegationOrder*(registry: LifecycleRegistry;
                      names: openArray[string]): CoreResult[seq[string]] =
  var wanted = newSeqWith(registry.cores.len, false)
  for name in names:
    let p = registry.findCore(name)
    if p < 0: return failure[seq[string]](ecManifest, "unknown core: " & name)
    wanted[p] = true
  result = success(newSeq[string]())
  var done = newSeqWith(registry.cores.len, false)
  while result.value.len < names.len:
    var progress = false
    for i, core in registry.cores:
      if not wanted[i] or done[i]: continue
      var ready = true
      for target in core.delegatesTo:
        let p = registry.findCore(target)
        if p < 0 or not wanted[p]:
          return failure[seq[string]](ecDelegation,
            core.name & " delegates to unavailable core " & target, @[target])
        if not done[p]: ready = false
      if ready:
        done[i] = true
        result.value.add core.name
        progress = true
    if result.value.len == names.len: break
    if not progress:
      var cycle: seq[string]
      for i, core in registry.cores:
        if wanted[i] and not done[i]: cycle.add core.name
      return failure[seq[string]](ecDelegation,
        "delegation cycle: " & cycle.join(", "), cycle)
  # Static validation also imposes the §13.4 four-hop maximum. Since targets
  # precede clients above, depths can be calculated in one stable pass.
  var depths = newSeqWith(registry.cores.len, 0)
  for name in result.value:
    let p = registry.findCore(name)
    for target in registry.cores[p].delegatesTo:
      let targetPos = registry.findCore(target)
      depths[p] = max(depths[p], depths[targetPos] + 1)
    if depths[p] > 4:
      return failure[seq[string]](ecDelegation,
        "delegation chain from " & name & " exceeds four hops", @[name])

proc sha256Hex*(data: openArray[byte]): string =
  const k = [
    0x428a2f98'u32,0x71374491'u32,0xb5c0fbcf'u32,0xe9b5dba5'u32,0x3956c25b'u32,0x59f111f1'u32,0x923f82a4'u32,0xab1c5ed5'u32,
    0xd807aa98'u32,0x12835b01'u32,0x243185be'u32,0x550c7dc3'u32,0x72be5d74'u32,0x80deb1fe'u32,0x9bdc06a7'u32,0xc19bf174'u32,
    0xe49b69c1'u32,0xefbe4786'u32,0x0fc19dc6'u32,0x240ca1cc'u32,0x2de92c6f'u32,0x4a7484aa'u32,0x5cb0a9dc'u32,0x76f988da'u32,
    0x983e5152'u32,0xa831c66d'u32,0xb00327c8'u32,0xbf597fc7'u32,0xc6e00bf3'u32,0xd5a79147'u32,0x06ca6351'u32,0x14292967'u32,
    0x27b70a85'u32,0x2e1b2138'u32,0x4d2c6dfc'u32,0x53380d13'u32,0x650a7354'u32,0x766a0abb'u32,0x81c2c92e'u32,0x92722c85'u32,
    0xa2bfe8a1'u32,0xa81a664b'u32,0xc24b8b70'u32,0xc76c51a3'u32,0xd192e819'u32,0xd6990624'u32,0xf40e3585'u32,0x106aa070'u32,
    0x19a4c116'u32,0x1e376c08'u32,0x2748774c'u32,0x34b0bcb5'u32,0x391c0cb3'u32,0x4ed8aa4a'u32,0x5b9cca4f'u32,0x682e6ff3'u32,
    0x748f82ee'u32,0x78a5636f'u32,0x84c87814'u32,0x8cc70208'u32,0x90befffa'u32,0xa4506ceb'u32,0xbef9a3f7'u32,0xc67178f2'u32]
  var msg = @data
  let bitLen = uint64(msg.len) * 8
  msg.add 0x80'u8
  while msg.len mod 64 != 56: msg.add 0'u8
  for shift in countdown(56, 0, 8): msg.add byte(bitLen shr shift)
  var h = [0x6a09e667'u32,0xbb67ae85'u32,0x3c6ef372'u32,0xa54ff53a'u32,
           0x510e527f'u32,0x9b05688c'u32,0x1f83d9ab'u32,0x5be0cd19'u32]
  for base in countup(0, msg.high, 64):
    var w: array[64, uint32]
    for i in 0..<16:
      let p = base + i*4
      w[i] = uint32(msg[p]) shl 24 or uint32(msg[p+1]) shl 16 or
             uint32(msg[p+2]) shl 8 or uint32(msg[p+3])
    for i in 16..<64:
      let s0 = rotateRightBits(w[i-15], 7) xor rotateRightBits(w[i-15], 18) xor (w[i-15] shr 3)
      let s1 = rotateRightBits(w[i-2], 17) xor rotateRightBits(w[i-2], 19) xor (w[i-2] shr 10)
      w[i] = w[i-16] + s0 + w[i-7] + s1
    var a=h[0]; var b=h[1]; var c=h[2]; var d=h[3]
    var e=h[4]; var f=h[5]; var g=h[6]; var hh=h[7]
    for i in 0..<64:
      let s1 = rotateRightBits(e,6) xor rotateRightBits(e,11) xor rotateRightBits(e,25)
      let t1 = hh + s1 + ((e and f) xor ((not e) and g)) + k[i] + w[i]
      let s0 = rotateRightBits(a,2) xor rotateRightBits(a,13) xor rotateRightBits(a,22)
      let t2 = s0 + ((a and b) xor (a and c) xor (b and c))
      hh=g; g=f; f=e; e=d+t1; d=c; c=b; b=a; a=t1+t2
    h[0]+=a; h[1]+=b; h[2]+=c; h[3]+=d
    h[4]+=e; h[5]+=f; h[6]+=g; h[7]+=hh
  for x in h: result.add toHex(x, 8).toLowerAscii

proc sha256Hex*(data: string): string =
  var bytes = newSeq[byte](data.len)
  for i, c in data: bytes[i] = byte(c)
  sha256Hex(bytes)

proc manifestMetadata*(content: string; mtimeNs: int64): ManifestMetadata =
  ManifestMetadata(size: int64(content.len), mtime: mtimeNs,
                   sha256: sha256Hex(content))

proc manifestMetadata*(path: string): ManifestMetadata =
  ## Size, modification time (nanoseconds since the epoch) and SHA-256 of an
  ## init.kg, as recorded at load and compared for staleness (§20.1).
  let content = readFile(path)
  let modified = getLastModificationTime(path)
  manifestMetadata(content, modified.toUnix * 1_000_000_000'i64 +
                   int64(modified.nanosecond))
