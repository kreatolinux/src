## Persistent sandbox completion state, stored as declarative Kongue.
import std/os
import ./rootfs/[types, state]

const
  envSetupStateFile* = rootfsStateFile
  envTargetStateFile* = rootfsStateFile

proc statePath(envRoot: string): string = envRoot / rootfsStateFile

proc initializeEnvState*(envRoot: string, profile: RootfsProfile,
    roots: seq[string], mode = rmSeeded,
    acquisition = amSeedThenBinary) =
  writeRootfsState(statePath(envRoot), RootfsState(schemaVersion: 1,
    status: rsProvisioning, target: profile.target,
    profileFingerprint: profile.fingerprint, rootMode: mode,
    acquisitionMode: acquisition, phase: rpPlanned, profile: profile,
    packageRoots: roots, extraPackages: profile.extraPackages,
    pendingPackages: roots))

proc mutateState(envRoot: string, status: RootfsStatus,
    phase: ProvisionPhase, pending: seq[string] = @[],
    completed: seq[string] = @[], failureStage = "",
    failurePackage = "") =
  var current = loadRootfsState(statePath(envRoot))
  current.status = status
  current.phase = phase
  current.pendingPackages = pending
  current.completedPackages = completed
  current.failureStage = failureStage
  current.failurePackage = failurePackage
  writeRootfsState(statePath(envRoot), current)

proc markEnvProvisioning*(envRoot: string, phase: ProvisionPhase,
    pending: seq[string] = @[], completed: seq[string] = @[]) =
  mutateState(envRoot, rsProvisioning, phase, pending, completed)

proc markEnvFailed*(envRoot, stage: string, package = "") =
  if fileExists(statePath(envRoot)):
    mutateState(envRoot, rsFailed, rpPlanned, failureStage = stage,
      failurePackage = package)

proc invalidateEnvSetup*(envRoot: string) =
  if fileExists(statePath(envRoot)):
    var current = loadRootfsState(statePath(envRoot))
    current.status = rsProvisioning
    current.phase = rpPlanned
    current.pendingPackages = current.packageRoots
    current.completedPackages.setLen(0)
    writeRootfsState(statePath(envRoot), current)
  if fileExists(envRoot / "envDateBuilt"): removeFile(envRoot / "envDateBuilt")

proc markEnvDeferred*(envRoot: string) =
  mutateState(envRoot, rsDeferred, rpFinalizing)
  if fileExists(envRoot / "envDateBuilt"): removeFile(envRoot / "envDateBuilt")

proc markEnvReady*(envRoot: string) =
  mutateState(envRoot, rsReady, rpComplete)
  writeFile(envRoot / "envDateBuilt", "ready")

proc canReuseEnv*(envRoot: string, deferPostInstall = false,
                  ignorePostInstall = false): bool =
  if not fileExists(envRoot / "etc/kreato-release") or
      not fileExists(statePath(envRoot)): return false
  try:
    let current = loadRootfsState(statePath(envRoot))
    case current.status
    of rsReady:
      current.phase == rpComplete and fileExists(envRoot / "envDateBuilt")
    of rsDeferred:
      deferPostInstall or (ignorePostInstall and
        current.failureStage == "postinstall_ignored")
    else: false
  except CatchableError:
    false

proc finishEnvSetup*(envRoot: string, updateTrust, postInstall: proc(),
                     deferPostInstall = false, ignorePostInstall = false,
                     publishReady = true) =
  invalidateEnvSetup(envRoot)
  if deferPostInstall:
    markEnvDeferred(envRoot)
    return
  markEnvProvisioning(envRoot, rpFinalizing)
  try:
    updateTrust()
    if ignorePostInstall:
      mutateState(envRoot, rsDeferred, rpFinalizing,
        failureStage = "postinstall_ignored")
      return
    postInstall()
    if publishReady:
      markEnvReady(envRoot)
    else:
      markEnvProvisioning(envRoot, rpFinalizing)
  except CatchableError:
    markEnvFailed(envRoot, "finalization")
    raise
