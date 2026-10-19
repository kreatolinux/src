## Production implementations of the resource steps of the load and unload
## procedures (§20.3 step 4-5, rollback, §20.4 steps 6-7) and of the
## cgroup-based busy check (§20.4 precondition 4), built on cgroups.nim and
## coredirs.nim. The daemon plugs the returned steps into
## lifecycle_exec.LoadCallbacks/UnloadCallbacks; init, supervisor, adapters,
## routing and dispatch steps come from the runtimes that own them.
import std/[os, tables]
import ../manifest/coredirs, ../lifecycle/lifecycle_exec
import jumpstartcore/[cgroups, errors]

type
  AccountLookup* = proc(core: string): CoreDirOwner {.closure.}
    ## The core's `account` in system mode; the daemon's user in user mode.
  PendingMounts* = proc(): seq[string] {.closure.}
  CoreHostConfig* = object
    userMode*: bool
    cgroupsAvailable*: bool
      ## System mode: cgroup v2 is mounted. User mode: a delegated subtree
      ## exists (`userDelegationAvailable`).
    cgroupRoot*: string        ## CorePaths.cgroupRoot (…/cores)
    stateRoot*, runtimeRoot*: string
    cgroupSystem*: CgroupSystem
    account*: AccountLookup
    filesystemsReady*: proc(): bool {.closure.}
    pendingMounts*: PendingMounts
  CoreHost* = ref object
    config*: CoreHostConfig
    layouts: Table[string, CoreCgroups]

const NativeCore* = "serviceHandler"

proc newCoreHost*(config: CoreHostConfig): CoreHost =
  if config.account.isNil or config.filesystemsReady.isNil or config.pendingMounts.isNil:
    raise newException(ValueError, "core host requires account, filesystems-ready and mount callbacks")
  if config.cgroupsAvailable and config.cgroupSystem.exists.isNil:
    raise newException(ValueError, "core host requires a cgroup system")
  CoreHost(config: config, layouts: initTable[string, CoreCgroups]())

proc toResult(e: ref CatchableError; code: CoreErrorCode): CoreResult[bool] =
  if e of CoreError: failure[bool]((ref CoreError)(e).code, e.msg)
  else: failure[bool](code, e.msg)

proc layout*(host: CoreHost; core: string): CoreCgroups =
  if host.layouts.hasKey(core): host.layouts[core]
  else: coreCgroups(host.config.cgroupRoot, core)

proc hasCgroup*(host: CoreHost; core: string): bool = host.layouts.hasKey(core)

proc controlProcs*(host: CoreHost; core: string): string =
  ## `ProcessSpec.cgroupProcs` for every process run for the core (§15.1
  ## rule 2), or "" when the core runs without cgroups (serviceHandler only).
  if host.layouts.hasKey(core): host.layouts[core].control / "cgroup.procs" else: ""

proc directories*(host: CoreHost; core: string): CoreDirectories =
  coreDirectories(host.config.stateRoot, host.config.runtimeRoot, core)

proc checkCgroupStep*(host: CoreHost): BoolStep =
  ## Part of step 4: extensions need cgroup v2 (and in user mode a delegated
  ## subtree); serviceHandler runs without cgroups when there are none.
  result = proc(core: string): CoreResult[bool] =
    if core != NativeCore and not host.config.cgroupsAvailable:
      return failure[bool](ecCgroup, if host.config.userMode:
        "no delegated cgroup subtree: extension cores cannot load"
        else: "cgroup v2 is unavailable: extension cores cannot load")
    success(true)

proc createCgroupStep*(host: CoreHost): BoolStep =
  ## Step 5: cores/CORE/{control,units} with controllers enabled, and in
  ## system mode delegation to a non-root account (§15.1 rules 1 and 4).
  result = proc(core: string): CoreResult[bool] =
    if not host.config.cgroupsAvailable:
      if core == NativeCore: return success(true)
      return failure[bool](ecCgroup, "cgroup v2 is unavailable")
    try:
      let sys = host.config.cgroupSystem
      let existing = coreCgroups(host.config.cgroupRoot, core)
      if sys.isDir(existing.core):
        # A leftover of a crashed earlier daemon: nothing is reused.
        killCore(existing, sys)
      let created = createCoreCgroups(host.config.cgroupRoot, core, sys)
      host.layouts[core] = created
      if not host.config.userMode:
        let owner = host.config.account(core)
        if owner.uid > 0: delegateCore(created, owner.uid, owner.gid, sys)
      success(true)
    except CatchableError as e:
      # A load that fails here is not rolled back by the caller (the step
      # never completed), so whatever was created is killed and removed now.
      let partial = coreCgroups(host.config.cgroupRoot, core)
      try: killCore(partial, host.config.cgroupSystem)
      except CatchableError: discard
      host.layouts.del(core)
      e.toResult(ecCgroup)

proc killCgroupStep*(host: CoreHost): BoolStep =
  ## Unload step 6 and rollback: cgroup.kill, wait for populated 0 (5 s),
  ## remove the subtree bottom-up.
  result = proc(core: string): CoreResult[bool] =
    if not host.layouts.hasKey(core): return success(true)
    try:
      killCore(host.layouts[core], host.config.cgroupSystem)
      host.layouts.del(core)
      success(true)
    except CatchableError as e:
      e.toResult(ecCgroup)

proc unitsPopulated*(host: CoreHost; core: string): tuple[available, populated: bool] =
  ## §20.4 busy check: `populated 1` in units/cgroup.events.
  if not host.layouts.hasKey(core): return (false, false)
  try: (true, cgroupPopulated(host.layouts[core].units, host.config.cgroupSystem))
  except CatchableError: (true, true)   # unknown counts as busy: fail closed

proc createRuntimeDirStep*(host: CoreHost): BoolStep =
  result = proc(core: string): CoreResult[bool] =
    try:
      host.directories(core).createRuntimeDir(host.config.account(core), core)
      success(true)
    except CatchableError as e:
      e.toResult(ecIo)

proc removeRuntimeDirStep*(host: CoreHost): BoolStep =
  result = proc(core: string): CoreResult[bool] =
    try:
      host.directories(core).removeRuntimeDir(core)
      success(true)
    except CatchableError as e:
      e.toResult(ecIo)

proc createStateDirStep*(host: CoreHost): BoolStep =
  ## Step 5 and its retries (filesystems ready, before each dispatch).
  result = proc(core: string): CoreResult[bool] =
    try:
      discard host.directories(core).ensureStateDir(host.config.account(core), core,
        host.config.filesystemsReady(), host.config.pendingMounts())
      success(true)
    except CatchableError as e:
      e.toResult(ecIo)
