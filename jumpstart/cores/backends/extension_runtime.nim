## Manifest-side helpers the daemon and jumpctl share: inspecting manifests
## for discovery (§8.2), building the dispatch plan of a loaded core
## (§11-§13, including `delegate` chains), and the built-in serviceHandler
## plan (Appendix A). Process execution lives in `backend_runtime`.
import std/[options, os, tables]
import ../manifest/[builtin_manifest, discovery, manifest, modes, types], ../lifecycle/dispatch
import jumpstartcore/[errors, registry, registry_types]

export dispatch.CoreDispatchPlan

proc toBackend*(op: ResolvedOp): ResolvedBackend =
  result.kind = dispatch.BackendKind(ord(op.backend))
  result.timeoutMs = op.timeoutMs
  result.sandbox = some(op.sandbox)
  result.user = op.user
  result.writablePaths = op.writablePaths
  result.network = op.network
  result.environment = initTable[string, string]()
  for key, value in op.environment: result.environment[key] = value
  result.workingDirectory = op.workingDirectory
  result.handler = op.handler
  result.executable = op.executable
  result.arguments = op.arguments
  result.execMode = dispatch.ExecMode(ord(op.execMode))
  result.delegateCore = op.delegateCore
  result.delegateOperation = op.delegateOperation

proc planFor*(name: string; manifestVersion: int; ops: openArray[ResolvedOp]): CoreDispatchPlan =
  ## Every resolved operation, `unsupported` entries included, so dispatch
  ## answers E_UNSUPPORTED for them (§11.4).
  result = initCoreDispatchPlan(name)
  for op in ops:
    let info = findOperation(manifestVersion, op.name)
    if info.isNone:
      raise newCoreError(ecManifest, "operation absent from registry: " & op.name, name)
    result.addOperation(info.get, toBackend(op))

proc delegationTargets*(ops: openArray[ResolvedOp]): seq[string] =
  for op in ops:
    if op.backend == manifest.bkDelegate and op.delegateCore notin result:
      result.add op.delegateCore

proc planFor*(m: CoreManifest; mode: CoreMode): CoreDispatchPlan =
  planFor(m.name, m.manifestVersion, m.resolveOps(mode))

proc definitionFor*(m: CoreManifest; mode: CoreMode): tuple[runtime: CoreRuntime;
                                                         plan: CoreDispatchPlan] =
  let ops = m.resolveOps(mode)
  result.plan = planFor(m.name, m.manifestVersion, ops)
  result.runtime = CoreRuntime(name: m.name, state: csUnloaded,
    activation: m.activation, hasUnitSubsystem: m.activation != asNone,
    delegatesTo: delegationTargets(ops))

proc nativePlan*(version: string; mode: CoreMode): CoreDispatchPlan =
  ## Appendix A: serviceHandler's compiled-in manifest.
  planFor("serviceHandler", CurrentManifestVersion, serviceHandlerOps(version, mode))

proc claimsUnit*(m: CoreManifest): bool =
  ## A core takes part in unit resolution when it claims the `unit`
  ## subsystem (§14.3).
  "unit" in m.subsystems

proc inspectManifest*(path: string; mode: CoreMode; version: string): ManifestInfo =
  ## Discovery's view of one manifest (§8.2). `delegationTargets` names the
  ## cores this mode's `delegate` backends target, so the delegation
  ## invariant (§9.4, §20.2 step 5) can be enforced.
  let name = splitPath(parentDir(path)).tail
  let m = loadManifest(path, name, version)
  result = ManifestInfo(name: m.name, modes: m.modes, referencedPaths: m.referencedPaths)
  if mode in m.modes:
    result.delegationTargets = delegationTargets(m.resolveOps(mode))

proc manifestInspector*(mode: CoreMode; version: string): ManifestInspector =
  result = proc(path: string): ManifestInfo = inspectManifest(path, mode, version)

proc loadExtensionManifest*(core: DiscoveredCore; version: string): CoreManifest =
  ## §20.3 step 2: read and validate the manifest afresh.
  loadManifest(core.path / "init.kg", core.name, version)

proc hasFunction*(m: CoreManifest; name: string): bool =
  ## `init` is required; `shutdown` is optional (§10.5).
  for fn in m.parsed.functions:
    if fn.funcName == name and fn.funcQualifier.len == 0: return true

proc hasUnitAddressedSubsystem*(m: CoreManifest): bool =
  for subsystem in m.subsystems:
    if subsystem in UnitAddressedSubsystems: return true
