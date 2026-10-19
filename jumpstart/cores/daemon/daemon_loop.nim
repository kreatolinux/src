## The event loop: one turn polls every descriptor and runs all ready work.
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

# ---------------------------------------------------------------------------
# Event loop

proc processParked*(d: Daemon) =
  if d.jobs.len == 0: return
  var jobs: seq[Job]
  swap(jobs, d.jobs)          # an explicit move: d.jobs collects the re-parked
  for job in jobs:
    if job.done or not job.parked: continue
    let stillWaiting = if not job.gate.isNil: job.gate()
                       elif job.parkCore.len > 0: d.coreLoading(job.parkCore)
                       else: d.anyLoading(d.callerLoadingCore(job))
    if stillWaiting and nowMs() < job.deadlineMs and not d.shuttingDown:
      d.jobs.add job
      continue
    job.parked = false
    if d.shuttingDown and not d.shutdownState.requestAllowed(requestName(job.request)):
      d.respond(job, errorResponse(ecShutdown, "the daemon is shutting down"))
      continue
    if stillWaiting:
      d.respond(job, errorResponse(ecTimeout, "timed out waiting for cores to load",
        job.parkCore))
      continue
    try: job.resume()
    except CoreError as e: d.respondError(job, e)
    except CatchableError as e: d.respond(job, errorResponse(uncodedErrorCode(e), e.msg))
    except Defect as e: d.respond(job, errorResponse(ecBackend, "internal error: " & e.msg))

proc processQueues*(d: Daemon) =
  # Calls promoted from §19.3 queues.
  while d.readyCalls.len > 0:
    let id = d.readyCalls.popFirst()
    let call = d.calls.getOrDefault(id)
    if not call.isNil and call.state == clQueued: d.execute(call)
  # Queued calls past their deadline (native operations have none).
  let now = nowMs()
  var expired: seq[Call]
  for _, id in d.queuedCalls:
    let call = d.calls.getOrDefault(id)
    if not call.isNil and call.deadlineMs > 0 and now >= call.deadlineMs: expired.add call
  for call in expired:
    discard d.resources.cancelQueuedOperation(call.target, call.klass, call.ticket)
    d.queuedCalls.del(callKey(call.target, call.klass, call.ticket))
    d.finishCall(call, errResult(ecTimeout, "operation timed out waiting for a slot"))
  # Native mutating calls whose §11.6 lock is free. Different units never wait
  # for each other: a call that may start does so even inside the frame of a
  # long one (the others stay queued, so that nested turn finds them).
  discard d.nativeLocks.takeTransitions()
  var starting: Call = nil
  var waiting = initDeque[int]()
  while d.nativeQueue.len > 0:
    let id = d.nativeQueue.popFirst()
    let call = d.calls.getOrDefault(id)
    if call.isNil or call.state != clNativeWait: continue
    var held = true
    try: held = d.nativeLocks.ticket(call.lockTicket).state == rsRunning
    except CatchableError: held = true
    if starting.isNil and held and (not call.nativeActivation or d.canStartNativeActivation()):
      starting = call
    else:
      waiting.addLast id
  d.nativeQueue = waiting
  if not starting.isNil:
    d.runNative(starting)
    return
  # Lifecycle procedures, one at a time, never inside a native operation, and
  # none starts once a shutdown was requested (§20.8: it must not wait behind
  # the loads that are still queued).
  if d.lifecycleQueue.len > 0 and d.canStartLifecycle() and not d.shutdownRequested and
      not d.shutdownRunning:
    let task = d.lifecycleQueue.popFirst()
    d.runLifecycleTask(task)

proc handleShutdownTriggers*(d: Daemon) =
  var trigger: ShutdownTrigger
  while takeShutdownTrigger(modeShutdown(d.config.mode), trigger):
    d.requestShutdown(trigger)

proc loopTurn*(d: Daemon; timeoutMs: int) =
  ## One loop turn: poll every descriptor, then do all ready work. Every
  ## step is guarded: no exception leaves a turn.
  inc d.depth
  defer: dec d.depth
  var fds: seq[TPollfd]
  var pidfds: seq[int]
  var timeout = timeoutMs
  d.guarded("poll set"):
    if not d.transport.isNil: d.transport.pollSet(fds)
    var others: seq[cint]
    for fd in d.driver.pollDescriptors(): others.add fd
    if d.config.shutdownTriggerFd >= 0: others.add d.config.shutdownTriggerFd
    for _, item in d.info:
      if not item.supervisor.isNil and item.supervisor.process.protocolReadFd >= 0:
        others.add item.supervisor.process.protocolReadFd
    # While a user daemon starts, the session model must not be re-entered.
    if d.sessionsEnabled and not d.sessionBusy: pidfds = d.sessions.model.peerPidfds()
    for fd in pidfds: others.add cint(fd)
    for fd in others:
      if fd >= 0: fds.add TPollfd(fd: fd, events: POLLIN)
    for fd in d.driver.writeDescriptors(): fds.add TPollfd(fd: fd, events: POLLOUT)
    let busy = d.driver.liveCount > 0 or d.jobs.len > 0 or d.queuedCalls.len > 0 or
      d.nativeQueue.len > 0 or d.lifecycleQueue.len > 0 or d.readyCalls.len > 0 or
      (not d.logging.isNil and d.logging.attachedPipeCount > 0) or d.info.len > 0 and
      (block:
        var any = false
        for _, item in d.info:
          if not item.supervisor.isNil: any = true
        any)
    if timeout < 0 or timeout > IdlePollMs: timeout = IdlePollMs
    if busy and timeout > BusyPollMs: timeout = BusyPollMs
    if d.readyCalls.len > 0 or
        (d.lifecycleQueue.len > 0 and d.canStartLifecycle() and not d.shutdownRequested):
      timeout = 0
  let ready = if fds.len == 0: posix.poll(nil, 0, cint(timeout))
              else: posix.poll(addr fds[0], Tnfds(fds.len), cint(timeout))
  if ready > 0:
    for pfd in fds:
      if pfd.revents == 0: continue
      if not d.transport.isNil and d.transport.owns(pfd.fd):
        try: d.transport.handle(pfd.fd, pfd.revents)
        except Exception as fault:
          # A connection that faults is dropped, so it cannot spin the loop.
          d.loopFault("control connection", fault)
          try: d.transport.abort(pfd.fd)
          except Exception: discard
      elif pfd.fd == d.config.shutdownTriggerFd:
        d.guarded("shutdown trigger"): d.handleShutdownTriggers()
      elif int(pfd.fd) in pidfds and d.sessionsEnabled and not d.sessionBusy:
        d.guarded("session peer"):
          d.sessionBusy = true
          defer: d.sessionBusy = false
          d.reloadLinger()
          for outcome in d.sessions.model.peerExited(int(pfd.fd)):
            if not outcome.ok: d.log(clWarn, "", "session: " & outcome.message)
  let now = nowMs()
  when defined(jumpstartTestHooks):
    d.guarded("test hook"):
      if not d.config.faultHook.isNil: d.config.faultHook()
  d.guarded("adapter runtime"):
    d.driver.pump(now)
    d.driver.advance(now)
  if d.reaper.waitErrors > d.reportedWaitErrors:
    d.reportedWaitErrors = d.reaper.waitErrors
    d.log(clError, "", "waitpid failed (children may be left unreaped): " &
      d.reaper.lastWaitError)
  d.guarded("runtime events"):
    while d.driver.hasEvents:
      let event = d.driver.nextEvent()
      try: d.handleRuntimeEvent(event)
      except Exception as fault: d.loopFault("runtime event", fault)
  d.guarded("completions"): d.processCompletions()
  d.guarded("supervisors"): d.pumpSupervisors()
  if not d.logging.isNil:
    try: discard d.logging.loggingTick()
    except Exception: discard
  if not d.config.sessions.tick.isNil:
    try: d.config.sessions.tick()
    except Exception as e: d.log(clWarn, "", "session runtime: " & e.msg)
  d.guarded("connection timers"):
    if not d.transport.isNil: d.transport.expire(now)
  d.guarded("parked requests"): d.processParked()
  d.guarded("queues"): d.processQueues()
  d.guarded("startup tail"): d.checkStartupTail()
  d.guarded("filesystems wait"): d.checkFilesystemsDeadline()
  if d.faulted:
    # A bounded pause, so a fault that repeats every turn cannot spin PID 1.
    d.faulted = false
    sleep(d.faultBackoffMs)

proc pauseLoop*(d: Daemon; ms: int) =
  ## A wait that keeps the daemon running (cgroup kills and removals).
  if d.nativeStack.len > 0 and not d.nativeStack[^1]:
    # A native operation that may not pump: only reap, then yield briefly.
    try: discard d.reaper.drain()
    except Exception: discard
    sleep(min(ms, 10))
  else:
    d.runOnce(ms)
