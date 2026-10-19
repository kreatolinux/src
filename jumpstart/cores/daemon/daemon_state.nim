## The daemon's shared state: its constants, the `Daemon` object and the small
## helpers every other daemon module uses (§14, §19.3, §20).
##
## The daemon is one reentrant state machine over this object; the other
## `daemon_*` modules each implement one concern of it, layered so that the
## imports never cycle:
##
##     daemon_state -> daemon_calls -> daemon_events -> daemon_routing
##       -> daemon_cores -> daemon_lifecycle -> daemon_jobs -> daemon_requests
##       -> daemon_loop -> daemon_boot -> daemon
##
## The event loop is above the layers that wait on it, so they reach it through
## `Daemon.turn` (set by `newDaemon`) instead of importing it.
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

const
  FilesystemsWaitMs* = 180_000'i64
    ## §20.2 (Revision 10 note): with `mount_fstab = false` the daemon waits
    ## for a core's `filesystems-ready` report or for every startup core to
    ## finish activation. A core whose activation never ends would hold that
    ## wait (and the buffered daemon log) forever, so the wait is bounded: after
    ## this long since startup the daemon declares the filesystems ready and
    ## logs that no report was received. The state directories stay protected by
    ## the pending-mount check (§20.3 step 5).
  NativeCallWaitMs* = 120_000'i64
    ## Bound of a Jumpstart-internal native call that waits for a §11.6 lock or
    ## a §19.3 slot and has no operation timeout (native operations declare
    ## none, §13.6): without it a lifecycle step could wait forever.
  RequestWaitMs* = 120_000'i64
    ## The one place a request-level wait limit is defined. §14.3 and §20.1
    ## say a request waits for a loading core "within the request's
    ## timeout", but the control protocol (§14.5) carries no per-request
    ## timeout, so the specification fixes no value: this is a resolved
    ## ambiguity (see the implementation report). It bounds only the wait for
    ## a core to finish loading. It is deliberately NOT applied to lock waits
    ## and queued §19.3 slots: §11.6 says those wait "until the lock is free
    ## or its own timeout expires", and native operations declare no timeout
    ## (§13.6), so a native request waits until the lock is free or the
    ## client goes away (§14.5). Extension operations queue for their
    ## manifest `timeout`.
  DrainLimitMs* = 90_000'i64              ## §20.4 step 3
  InitTimeoutMs* = 60_000'i64             ## §20.3 step 6
  AdapterStartSlackMs* = 30_000'i64       ## handshake 10 s + §13.7 escalation
  CancelSettleMs* = CancellationGraceMs + 5_000'i64
    ## After a cancel, §13.7 needs SIGTERM, up to 5 s, SIGKILL and the exit to
    ## be reaped: waiting less than the grace would give up before the kill.
  NoDeadline* = high(int64) div 4         ## native lock waits have no timeout
  FaultBackoffMinMs* = 10
  FaultBackoffMaxMs* = 250
  FaultQuietMs* = 5_000'i64               ## no fault for this long resets the backoff
  IdlePollMs* = 1000
  BusyPollMs* = 20


type
  FrameKind* = enum fkLifecycle, fkNativeMutating, fkNativeActivation

  CallState* = enum clNew, clQueued, clNativeWait, clRunning, clDone

  CallResult* = object
    ok*: bool
    value*: JsonNode
    code*: CoreErrorCode
    message*: string

  Call* = ref object
    id*: int
    core*, operation*, unit*: string
    args*: JsonNode
    internal*: bool
    plan*: DispatchPlan
    target*, targetOp*: string
    klass*: res.OperationClass
    ticket*: uint64
    admitted*: bool
    state*: CallState
    requestId*: string
    deadlineMs*: int64
    native*: bool
    lockTicket*: uint64        ## native mutating: §11.6 lock ticket (0 = none)
    logged*: bool              ## §19.2 start line written
    logId*: string
    scope*: OperationLogScope
    onEntry*: proc(entry: JsonNode) {.closure.}
    onDone*: proc(r: CallResult) {.closure.}
    result*: CallResult

  ParkKind* = enum pkLoading, pkUnqualified
  Job* = ref object
    request*: ControlRequest
    ctx*: RequestContext
    peer*: PeerCredentials
    deadlineMs*: int64
    done*: bool
    parked*: bool
    parkCore*: string          # qualified wait: the core; "" = any loading core
    resume*: proc() {.closure.}
    gate*: proc(): bool {.closure.}   # extra wait condition (session runtime busy)
    calls*: seq[Call]
    callerCore*: string
    callerKnown*: bool

  CoreInfo* = object
    native*: bool
    manifest*: CoreManifest
    plan*: CoreDispatchPlan
    claimsUnit*: bool
    closed*: bool
    initDone*: bool
    stateDirDone*: bool
    stateDirError*: string       ## last creation failure, logged once per message
    activeCalls*: HashSet[int]
    unitSubsystems*: Table[string, string]
    supervisor*: SupervisorRuntime

  LifecycleKind* = enum lkLoad, lkUnload, lkReload
  LifecycleTask* = object
    kind*: LifecycleKind
    core*: string
    stopUnits*: bool
    startup*: bool
    done*: proc(r: CoreResult[bool]) {.closure.}

  SessionHooks* = object
    ## System mode: §7.6 session handling (nil in user mode).
    tick*: proc() {.closure.}
    runningUsers*: proc(): seq[int] {.closure.}

  DaemonConfig* = object
    mode*: CoreMode
    version*: string                  ## "jumpstart vX.Y.Z"
    paths*: CorePaths
    roots*: seq[CoreRoot]
    statePaths*: StatePaths
    discoveryOptions*: DiscoveryOptions
    trustedPeerUid*: int              ## §7.4 rules 5-6
    cgroupsAvailable*: bool
    cgroupMount*: string              ## for /proc/PID/cgroup paths
    cgroupSystem*: CgroupSystem
    filesystemsReady*: bool           ## §20.2 at startup
    mountFstab*: bool                 ## false: cores mount; readiness is awaited (§20.2)
    filesystemsWaitMs*: int64         ## bound of that wait; 0 = FilesystemsWaitMs
    runtime*: RuntimeConfig           ## backend runtime (runner, identity…)
    native*: ServiceHandlerCallbacks
    logger*: CoreLogger
    account*: AccountLookup
    pendingMounts*: PendingMounts
    listenFd*: cint                   ## bound control socket, or -1
    shutdownTriggerFd*: cint          ## installShutdownTriggers, or -1
    linuxShutdown*: LinuxShutdownConfig
    linuxSystem*: LinuxShutdownSystem ## system mode final sequence
    sessions*: SessionHooks
    procRoot*: string                 ## "/proc"
    requestWaitMs*: int64
    onExit*: proc(status: int) {.closure.}  ## user mode final action
    when defined(jumpstartTestHooks):
      faultHook*: proc() {.closure.}
        ## Test builds only: called once per loop turn inside the guard, so a
        ## test can inject an exception and see the loop survive it.

  Daemon* = ref object
    config*: DaemonConfig
    reaper*: Reaper
    driver*: AdapterRuntime
    backend*: BackendRuntime
    host*: CoreHost
    server*: ControlServer
    transport*: ControlTransport
    resources*: RuntimeResources
    registry*: LifecycleRegistry
    discovered*: DiscoveryResult
    discoveryError*: Option[(CoreErrorCode, string)]
      ## Why discovery failed (§8.3), so `cores status` shows the real code.
    enabled*: seq[string]
    stateError*: Option[(CoreErrorCode, string)]
    plans*: Table[string, CoreDispatchPlan]
    info*: Table[string, CoreInfo]
    nameIndexes*: nameidx.NameIndexStore
    loadOrder*: seq[string]
    startupPending*: HashSet[string]
    startupActivations*: HashSet[string]
    startupDone*: bool
    filesystemsDeadlineMs*: int64      ## 0: not waiting for filesystems
    lingerStarted*: bool
    calls*: Table[int, Call]
    nextCall*: int
    byRequest*: Table[string, int]
    syncCompletions*: Table[string, Completion]
    syncWaiting*: HashSet[string]
    queuedCalls*: Table[string, int]
    readyCalls*: Deque[int]
    nativeQueue*: Deque[int]
    nativeLocks*: LockManager          ## §11.6 unit/core/log locks of native calls
    enabledReadError*: string
    faultBackoffMs*: int
    faulted*: bool
    reportedWaitErrors*: int
    lastFaultMs*: int64
    faultCount*: int                  ## loop faults survived since start
    lifecycleQueue*: Deque[LifecycleTask]
    lifecycleBusy*: bool
    frames*: seq[FrameKind]
    nativeStack*: seq[bool]            # true: the running native call may pump
    jobs*: seq[Job]
    depth*: int
    userEnv*: Table[string, string]
    shutdownState*: ShutdownState
    shutdownRequested*: bool
    shutdownRunning*: bool
    shuttingDown*: bool
    unloadDeadlineMs*: int64
    exitRequested*: bool
    exitStatus*: int
    filesystemsReady*: bool
    sessions*: SessionManager
    sessionsEnabled*: bool
    sessionBusy*: bool
    logging*: CoreLoggingManager
    turn*: proc(timeoutMs: int) {.closure.}
      ## One event-loop turn; the loop (daemon_loop) installs it, so the layers
      ## below it can wait with nested turns without importing it.

# ---------------------------------------------------------------------------
# Small helpers

proc nowMs*(): int64 = getMonoTime().ticks div 1_000_000

proc sessionNow*(): MonotonicSeconds = nowMs() div 1000

proc coreError*(code: CoreErrorCode; message: string; core = ""): ref CoreError =
  newCoreError(code, message, core)

proc log*(d: Daemon; level: CoreLogLevel; core, message: string) =
  if d.config.logger.isNil: return
  try:
    if core.len > 0: d.config.logger.logCore(level, core, message)
    else: d.config.logger.log(level, "jumpstart", message)
  except CatchableError: discard

proc loopFault*(d: Daemon; what: string; e: ref Exception) =
  ## One failed step of the event loop. PID 1 must never die from it (an
  ## exiting PID 1 is a kernel panic): the error is logged, the loop goes on
  ## and a persistent fault is slowed down instead of spinning.
  inc d.faultCount
  let now = nowMs()
  if now - d.lastFaultMs > FaultQuietMs: d.faultBackoffMs = 0
  d.lastFaultMs = now
  d.faultBackoffMs = if d.faultBackoffMs == 0: FaultBackoffMinMs
                     else: min(d.faultBackoffMs * 2, FaultBackoffMaxMs)
  d.faulted = true
  d.log(clError, "", "event loop fault in " & what & ": " & $e.name & ": " & e.msg)

template guarded*(d: Daemon; what: string; body: untyped) =
  try:
    body
  except Exception as fault:
    d.loopFault(what, fault)

proc stateName*(state: CoreState): string = ($state)[2 .. ^1].toLowerAscii

proc pos*(d: Daemon; core: string): int = d.registry.findCore(core)

proc stateOf*(d: Daemon; core: string): CoreState =
  let p = d.pos(core)
  if p < 0: csUnloaded else: d.registry.cores[p].state

proc isNative*(core: string): bool = core == NativeCore

proc okResult*(value: JsonNode): CallResult =
  CallResult(ok: true, value: if value.isNil: newJObject() else: value)

proc errResult*(code: CoreErrorCode; message: string): CallResult =
  CallResult(ok: false, code: code, message: message)

proc toResponse*(r: CallResult; core: string; warnings: seq[string] = @[]): ControlResponse =
  if r.ok:
    result = okResponse(r.value, warnings)
  else:
    result = errorResponse(r.code, r.message)
  result.core = core

proc infoOf*(d: Daemon; core: string): var CoreInfo =
  if not d.info.hasKey(core): d.info[core] = CoreInfo()
  d.info[core]

proc modeShutdown*(mode: CoreMode): ShutdownMode =
  if mode == cmSystem: smSystem else: smUser

proc modeText*(mode: CoreMode): string =
  if mode == cmSystem: "system" else: "user"


# ---------------------------------------------------------------------------
# Name index (§14.3)

proc unitNames*(value: JsonNode): seq[string] =
  if value.isNil or value.kind != JObject or not value.hasKey("units"): return
  for item in value["units"]:
    if item.kind == JObject and item.hasKey("name") and item["name"].kind == JString:
      result.add item["name"].getStr

proc indexRefresh*(d: Daemon; core: string; names: seq[string]) =
  try: nameidx.refresh(d.nameIndexes, core, names)
  except CatchableError as e: d.log(clWarn, core, "name index not written: " & e.msg)

proc indexOwned*(d: Daemon; core, requested, canonical: string) =
  try: nameidx.recordOwned(d.nameIndexes, core, requested, canonical)
  except CatchableError as e: d.log(clWarn, core, "name index not written: " & e.msg)


proc runOnce*(d: Daemon; timeoutMs: int) =
  ## One loop turn: poll every descriptor, then do all ready work (the body is
  ## `loopTurn` in daemon_loop).
  d.turn(timeoutMs)
