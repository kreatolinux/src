## Environment store (§7.5, §21.9), user sessions (§7.6), power and users jobs.
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

# ---------------------------------------------------------------------------
# Environment store (§7.5, §21.9), sessions, power, users

proc envJob*(d: Daemon; job: Job) =
  let request = job.request.env
  if d.config.mode != cmUser:
    d.respond(job, errorResponse(ecUsage, "env is only available in user mode"))
    return
  proc check(key: string) =
    if not validEnvironmentName(key) or isProtectedUserVariable(key):
      raise coreError(ecUsage, "invalid or protected environment variable: " & key)
  try:
    case request.action
    of "list":
      var keys: seq[string]
      for key in d.userEnv.keys: keys.add key
      keys.sort(system.cmp[string])
      var vars = newJObject()
      for key in keys: vars[key] = %d.userEnv[key]
      d.respond(job, okResponse(%*{"vars": vars}))
    of "set":
      for key, value in request.vars:
        check(key)
        if value.kind != JString: raise coreError(ecUsage, "env set needs a value for " & key)
      for key, value in request.vars: d.userEnv[key] = value.getStr
      d.respond(job, okResponse(%*{"changed": request.vars.len}))
    of "unset":
      var changed = 0
      for key, _ in request.vars:
        check(key)
      for key, _ in request.vars:
        if d.userEnv.hasKey(key): inc changed
        d.userEnv.del(key)
      d.respond(job, okResponse(%*{"changed": changed}))
    of "import":
      # The client sends the values it has; a null value names a variable
      # that is not set in its environment, which is reported and skipped.
      var skipped: seq[string]
      var imported = 0
      for key, _ in request.vars: check(key)
      for key, value in request.vars:
        if value.kind == JString:
          d.userEnv[key] = value.getStr
          inc imported
        else: skipped.add key
      var warnings: seq[string]
      for key in skipped: warnings.add key & " is not set; skipped"
      d.respond(job, okResponse(%*{"changed": imported, "skipped": skipped}, warnings))
    else:
      d.respond(job, errorResponse(ecUsage, "unknown env action: " & request.action))
  except CoreError as e: d.respondError(job, e)

proc reloadLinger*(d: Daemon) =
  ## §7.6.6, §21.8: `jumpctl users linger` writes the root-owned markers
  ## locally, so the daemon reads them again at every session event and for
  ## `users list`. Disabling linger for a user without sessions stops their
  ## daemon; one that still has sessions keeps running.
  if not d.sessionsEnabled: return
  try: d.sessions.loadLinger()
  except CatchableError as e: d.log(clWarn, "", "linger markers not re-read: " & e.msg)

proc sessionJob*(d: Daemon; job: Job) =
  if d.config.mode != cmSystem:
    d.respond(job, errorResponse(ecUsage, "sessions are only available in system mode"))
    return
  if not d.sessionsEnabled:
    d.respond(job, errorResponse(ecUnsupported, "session runtime is unavailable"))
    return
  if d.sessionBusy:
    # A user daemon start runs nested loop turns; session requests that
    # arrive meanwhile wait for it instead of re-entering the model.
    let rt = d
    job.gate = proc(): bool = rt.sessionBusy
    d.park(job, "", proc() = rt.sessionJob(job))
    return
  let request = job.request.session
  var accepted = AcceptedPeer(pid: int(job.peer.pid), uid: SessionUid(max(job.peer.uid, 0)),
    acceptedAt: job.peer.acceptedAt, peerPidfd: -1)
  if job.peer.uid < 0: accepted.uid = high(SessionUid)
  # The model takes ownership of the pidfd only for a real open request.
  var handOver = request.action == "open" and request.uid > 0 and job.peer.uid == 0 and
    job.peer.pidfd >= 0 and uint64(request.uid) <= uint64(high(SessionUid))
  if handOver and not d.sessions.accounts.byUid.isNil:
    try:
      let account = d.sessions.accounts.byUid(SessionUid(request.uid))
      handOver = account.uid == SessionUid(request.uid) and account.name.len > 0 and
        account.home.len > 0
    except CatchableError: handOver = false
  if handOver:
    # The transport keeps the connection's own descriptor until the link ends;
    # the session model owns a duplicate for as long as the session lives.
    let owned = fcntl(cint(job.peer.pidfd), F_DUPFD_CLOEXEC, cint(3))
    if owned >= 0: accepted.peerPidfd = int(owned)
  d.sessionBusy = true
  defer: d.sessionBusy = false
  try:
    d.reloadLinger()
    d.respond(job, d.sessions.handleSession(request, accepted, sessionNow()))
  except CoreError as e: d.respondError(job, e)
  except CatchableError as e: d.respond(job, errorResponse(uncodedErrorCode(e), e.msg))

proc usersJob*(d: Daemon; job: Job) =
  if d.config.mode != cmSystem:
    d.respond(job, errorResponse(ecUsage, "users is only available in system mode"))
    return
  if not d.sessionsEnabled:
    d.respond(job, okResponse(%*{"users": newJArray()}))
    return
  if not d.sessionBusy:
    d.sessionBusy = true
    defer: d.sessionBusy = false
    d.reloadLinger()
  d.respond(job, d.sessions.handleUsers(job.request.users, true, sessionNow()))

proc abortQueuedLifecycle*(d: Daemon) =
  ## §20.8: loads and unloads that have not started do not run once a
  ## shutdown was requested; each waiting `cores` request is answered.
  while d.lifecycleQueue.len > 0:
    let task = d.lifecycleQueue.popFirst()
    d.startupPending.excl task.core
    d.log(clInfo, task.core, "queued " & ($task.kind)[2 .. ^1].toLowerAscii &
      " skipped: the daemon is shutting down")
    if not task.done.isNil:
      try: task.done(failure[bool](ecShutdown, "the daemon is shutting down"))
      except CatchableError: discard

proc requestShutdown*(d: Daemon; trigger: ShutdownTrigger) =
  case d.shutdownState.trigger(trigger, proc(message: string) = d.log(clInfo, "", message))
  of trStarted:
    d.shutdownRequested = true
    d.shuttingDown = true        # §20.8 step 1 takes effect at once
    d.log(clInfo, "", "shutdown requested: " & $trigger)
    d.abortQueuedLifecycle()
  else: discard

proc powerJob*(d: Daemon; job: Job) =
  if d.config.mode != cmSystem:
    d.respond(job, errorResponse(ecUsage, "power is only available in system mode"))
    return
  let action = job.request.power.action
  var trigger: ShutdownTrigger
  try: trigger = powerTrigger(action)
  except ValueError:
    d.respond(job, errorResponse(ecUsage, "unknown power action: " & action))
    return
  d.respond(job, okResponse(%*{"action": action}))
  d.requestShutdown(trigger)
