import std/tables

type
  RootfsStatus* = enum
    rsProvisioning = "provisioning"
    rsDeferred = "deferred"
    rsReady = "ready"
    rsFailed = "failed"

  RootMode* = enum
    rmEmpty = "empty"
    rmSeeded = "seeded"

  AcquisitionMode* = enum
    amBinariesOnly = "binaries_only"
    amSeedThenBinary = "seed_then_binary"
    amBuildMissing = "build_missing"

  PackageMode* = enum
    pmBinary = "binary"
    pmBuild = "build"

  ProvisionPhase* = enum
    rpPlanned = "planned"
    rpAcquiring = "acquiring"
    rpAcquired = "acquired"
    rpRemoving = "removing"
    rpInstalling = "installing"
    rpFinalizing = "finalizing"
    rpComplete = "complete"

  RootfsProfile* = object
    schemaVersion*: int
    arch*: string
    os*: string
    libc*: string
    compiler*: string
    coreutils*: string
    init*: string
    tlsLibrary*: string
    packageRoots*: seq[string]
    extraPackages*: seq[string]
    target*: string
    fingerprint*: string

  RootfsConfig* = object
    schemaVersion*: int
    buildDirectory*: string
    packageMode*: PackageMode
    useOverlay*: bool
    profile*: RootfsProfile

  RootfsState* = object
    schemaVersion*: int
    status*: RootfsStatus
    target*: string
    profileFingerprint*: string
    rootMode*: RootMode
    acquisitionMode*: AcquisitionMode
    phase*: ProvisionPhase
    profile*: RootfsProfile
    packageRoots*: seq[string]
    extraPackages*: seq[string]
    pendingPackages*: seq[string]
    completedPackages*: seq[string]
    failureStage*: string
    failurePackage*: string

  RootfsPlan* = object
    profile*: RootfsProfile
    sourceProfile*: RootfsProfile
    mode*: RootMode
    acquire*: seq[string]
    remove*: seq[string]
    install*: seq[string]
    exclusions*: seq[string]

  ArtifactProvider* = proc(package, target: string) {.closure.}
  PackageMutation* = proc(package: string) {.closure.}
  PhaseCallback* = proc(phase: ProvisionPhase, pending,
      completed: seq[string]) {.closure.}

  DeclarativeKongueError* = object of CatchableError
  KongueDocument* = object
    scalars*: OrderedTable[string, string]
    lists*: OrderedTable[string, seq[string]]
