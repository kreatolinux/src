## The running Jumpstart daemon: routing, dispatch, the live core lifecycle,
## and the event loop (§5, §14, §19.3, §20).
##
## Design. The daemon is single threaded. One `poll` loop (`runOnce`) waits
## on the listening socket, every client connection, the reaper's wakeup
## descriptor, the shutdown-trigger descriptor, every adapter and runner pipe,
## supervisor protocol pipes and session pidfds, so signals, reaping and
## clients stay responsive whatever runs (§14.5, §15.3).
##
## * Extension operations never block: they are submitted to the
##   non-blocking adapter runtime and finish through completions.
## * Requests that must wait (for a loading core, a lock, or a §19.3 queue
##   slot) are parked as continuations and resumed by later loop turns. A
##   waiting request never holds a stack frame, so waits cannot deadlock on
##   each other.
## * Steps that are synchronous by nature (the §20.3/§20.4 procedures, the
##   native serviceHandler, the supervisor handshake, session start) run
##   nested loop turns while they wait (`waitUntil`). Frame rules keep this
##   safe: one lifecycle procedure at a time, native mutating operations one
##   at a time (except under the lock-free native activation, §11.6), and no
##   lifecycle procedure starts inside a native operation.
##
## Layout. The state machine is one `Daemon` object (daemon_state) and one
## module per concern, each importing only the ones before it: daemon_calls
## (call admission, native locks, nested waits), daemon_events (runtime events,
## completions, filesystems ready), daemon_routing (request routing and
## fan-out), daemon_cores (core listing), daemon_lifecycle (load/unload
## callbacks, activation), daemon_jobs (env, sessions, power, users),
## daemon_requests (entry point), daemon_loop (the event loop) and daemon_boot
## (startup, shutdown, `serve`). This module builds the daemon, wires the
## transport and re-exports the public API, so `import daemon` is unchanged.
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
import ./daemon_boot

export control,
  discovery,
  errors,
  lifecycle,
  native_api,
  server,
  state,
  types,
  shutdown

# The public surface of the daemon, as it was when this was one module.
export daemon_state.FilesystemsWaitMs, daemon_state.NativeCallWaitMs,
  daemon_state.RequestWaitMs, daemon_state.CallResult, daemon_state.SessionHooks,
  daemon_state.DaemonConfig, daemon_state.Daemon, daemon_state.stateOf,
  daemon_state.runOnce
export daemon_calls.nativePump, daemon_calls.waitUntil
export daemon_events.markFilesystemsReady
export daemon_jobs.requestShutdown
export daemon_requests.handleRequest
export daemon_loop.pauseLoop
export daemon_boot.startup, daemon_boot.runShutdownSequence, daemon_boot.serve

# ---------------------------------------------------------------------------
# Construction

proc newDaemon*(config: DaemonConfig; reaper: Reaper): Daemon =
  ## Build the daemon around an already bound control socket (§20.2 step 2
  ## happens before discovery). Call `startup` next.
  if reaper.isNil: raise newException(ValueError, "a central reaper is required")
  var cfg = config
  if cfg.requestWaitMs <= 0: cfg.requestWaitMs = RequestWaitMs
  if cfg.procRoot.len == 0: cfg.procRoot = "/proc"
  if cfg.cgroupMount.len == 0: cfg.cgroupMount = "/sys/fs/cgroup"
  if cfg.account.isNil:
    let uid = if cfg.mode == cmUser: cfg.paths.uid else: -1
    cfg.account = proc(core: string): CoreDirOwner = CoreDirOwner(uid: uid, gid: -1)
  if cfg.pendingMounts.isNil:
    cfg.pendingMounts = proc(): seq[string] = @[]
  let d = Daemon(config: cfg, reaper: reaper)
  d.nativeLocks = initLockManager()
  d.turn = proc(timeoutMs: int) = d.loopTurn(timeoutMs)
  # §15.3: children nobody registered are reaped and logged at debug.
  reaper.onUnowned = proc(status: ChildStatus) =
    d.log(clDebug, "", "reaped unowned child pid " & $status.pid & " (" &
      (case status.kind
       of cekExited: "exit " & $status.code
       of cekSignaled: "signal " & $status.code
       else: "status " & $status.raw) & ")")
  # Waits inside cgroup kills and removals keep the loop running (§14.5,
  # §15.3: PID 1 never stalls), instead of sleeping.
  if not d.config.cgroupSystem.pause.isNil:
    d.config.cgroupSystem.pause = proc(ms: int) = d.pauseLoop(ms)
  d.filesystemsReady = cfg.filesystemsReady or cfg.mode == cmUser
  d.driver = initAdapterRuntime(modeText(cfg.mode), runningVersionNumber(cfg.version), reaper)
  var rc = cfg.runtime
  rc.mode = cfg.mode
  if rc.jumpstartVersion.len == 0: rc.jumpstartVersion = runningVersionNumber(cfg.version)
  let daemon = d
  if cfg.mode == cmUser and rc.userStore.isNil:
    rc.userStore = proc(): Environment =
      result = initTable[string, string]()
      for key, value in daemon.userEnv: result[key] = value
  d.backend = newBackendRuntime(rc, d.driver)
  d.host = newCoreHost(CoreHostConfig(userMode: cfg.mode == cmUser,
    cgroupsAvailable: cfg.cgroupsAvailable, cgroupRoot: cfg.paths.cgroupRoot,
    stateRoot: cfg.paths.stateRoot, runtimeRoot: cfg.paths.runtimeRoot,
    cgroupSystem: d.config.cgroupSystem, account: cfg.account,
    filesystemsReady: proc(): bool = daemon.filesystemsReady,
    pendingMounts: cfg.pendingMounts))
  d.resources = initRuntimeResources(filesystemsReady = d.filesystemsReady)
  d.shutdownState = initShutdownState(modeShutdown(cfg.mode))
  d.userEnv = initTable[string, string]()
  if not cfg.logger.isNil:
    d.logging = newCoreLoggingManager(cfg.logger)
    if d.filesystemsReady:
      try: discard cfg.logger.setFilesystemsReady()
      except CatchableError: discard
  d.nameIndexes = nameidx.initNameIndexStore(cfg.paths.nameIndexRoot)
  d

proc attachSessions*(d: Daemon; manager: SessionManager) =
  d.sessions = manager
  d.sessionsEnabled = true

proc attachTransport*(d: Daemon; listenFd: cint) =
  ## Serve the control socket (§14.5, §19.3 connection limit).
  let rt = d
  d.server = newControlServer(
    proc(request: ControlRequest; context: RequestContext) = rt.handleRequest(request, context),
    proc(peer: PeerCredentials): bool = peer.uid == int64(rt.config.trustedPeerUid))
  d.transport = newControlTransport(listenFd, d.server, proc(): int64 = nowMs(),
    proc(fd: cint): PeerCredentials =
      # SO_PEERCRED (getpeereid on development hosts), then SO_PEERPIDFD and
      # the acceptance time in /proc start-time units where Linux has them.
      let cred = peerCredentials(fd)
      result = PeerCredentials(uid: cred.uid, gid: cred.gid, pid: int64(cred.pid),
        pidfd: -1)
      try: result.acceptedAt = bootTimeTicks()
      except CatchableError: result.acceptedAt = 0
      try: result.pidfd = int(peerPidfd(fd))
      except CatchableError: result.pidfd = -1)

# ---------------------------------------------------------------------------
# Introspection for tests

proc manifestAccount*(d: Daemon; core: string): string =
  ## The `account` of a core being loaded or loaded (§10.4), or "".
  if d.info.hasKey(core) and not d.info[core].native: d.info[core].manifest.account
  else: ""

proc loadedCores*(d: Daemon): seq[string] =
  for name in d.loadOrder:
    if d.stateOf(name).isLoaded: result.add name

proc idle*(d: Daemon): bool =
  d.lifecycleQueue.len == 0 and not d.lifecycleBusy and d.startupPending.len == 0 and
    d.startupActivations.len == 0 and d.calls.len == 0

