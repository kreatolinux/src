## Process-free data model consumed by lifecycle.nim.
type
  CoreState* = enum
    csUnloaded, csLoading, csLoaded, csUnloading, csFailed, csDegraded

  ActivationStrategy* = enum
    asNone, asCore, asPerUnit, asNative

  UnitRuntimeState* = enum
    ursInactive, ursActive, ursActivating, ursDeactivating, ursReloading, ursFailed

  UnitSnapshot* = object
    name*: string
    subsystem*: string
      ## From `unit.list`; empty when unknown (native units). §20.4 ignores
      ## active `mount` and `swap` units, so the busy check needs it.
    enabled*: bool
    state*: UnitRuntimeState

  ManifestMetadata* = object
    ## `sha256` is lowercase hexadecimal. Empty means digest unavailable.
    size*: int64
    mtime*: int64
    sha256*: string

  CoreRuntime* = object
    name*: string
    state*: CoreState
    delegatesTo*: seq[string]
    activation*: ActivationStrategy
    hasUnitSubsystem*: bool
    loadedManifest*: ManifestMetadata
    failure*: string

  LifecycleRegistry* = object
    cores*: seq[CoreRuntime]

  BusySnapshot* = object
    cgroupAvailable*: bool
    cgroupPopulated*: bool
    units*: seq[UnitSnapshot]

  UnloadOptions* = object
    stopUnits*: bool
    daemonShutdown*: bool

  ActivationActionKind* = enum
    aaActivateCore, aaStartUnit, aaReachNativeTarget

  ActivationAction* = object
    kind*: ActivationActionKind
    unit*: string

