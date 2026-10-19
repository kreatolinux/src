## Concrete, event-loop-friendly supervisor process integration (§15.2).
##
## `SupervisorRuntime` owns only the supervisor process descriptors. The
## central `Reaper` remains the sole waitpid owner; callers drain it and then
## call `pumpSupervisor`/`advanceSupervisor`. `awaitSupervisorReady` and
## `stopSupervisorBlocking` are the production building blocks for load step 7
## and unload step 5 (and rollback) of §20.3/§20.4.
import std/[json, os, strutils]
import posix
import ../daemon/logging, ./supervisor, ../manifest/types
import jumpstartcore/[errors, reaper, spawn]

type
  SupervisorRuntimeEventKind* = enum
    sreReady, sreNotification, sreNotificationDropped, sreExited,
    sreHandshakeTimeout, sreProtocolError, sreFilesystemsReady
  SupervisorRuntimeEvent* = object
    kind*: SupervisorRuntimeEventKind
    unit*: string
    detail*: string
    status*: ChildStatus
    transition*: SupervisorExitTransition
  SupervisorRuntime* = ref object
    model*: SupervisorModel
    process*: SpawnedProcess
    readBuffer: string
    protocolEof*: bool
    inputClosed*: bool
    terminated*: bool
    exited*: bool
    exitStatus*: ChildStatus
    pendingExits: seq[ChildStatus]
    reaper: Reaper
  SupervisorClock* = proc(): int64 {.closure.}
    ## Milliseconds from a monotonic clock.
  SupervisorPause* = proc(milliseconds: int) {.closure.}
  SupervisorEventSink* = proc(event: SupervisorRuntimeEvent) {.closure.}

const
  SupervisorReapGraceMs* = 5_000'i64
    ## After SIGKILL, how long the blocking stop waits for the reaper to see
    ## the exit before giving up (the cgroup kill then removes leftovers).
  MaxReadPerPass = 64 * 1024
    ## Bytes read from the supervisor's fd 4 per pump pass.

proc setNonBlocking(fd: cint) =
  let flags = fcntl(fd, F_GETFL)
  if flags < 0 or fcntl(fd, F_SETFL, flags or O_NONBLOCK) < 0:
    raiseOSError(osLastError())

proc writeAll(fd: cint; value: string) =
  var offset = 0
  while offset < value.len:
    let count = posix.write(fd, unsafeAddr value[offset], value.len - offset)
    if count > 0: offset += int(count)
    elif count < 0 and osLastError() == OSErrorCode(EINTR): discard
    else: raiseOSError(osLastError(), "writing supervisor protocol")

proc signalProcess(runtime: SupervisorRuntime; signal: cint) =
  ## Signals only a registered, unreaped child, so a reused PID is never hit.
  if runtime.process.pid <= 0 or runtime.exited: return
  if not runtime.reaper.isNil:
    discard runtime.reaper.signalChild(runtime.process.pid, signal)
  elif kill(runtime.process.pid, signal) != 0 and
      osLastError() != OSErrorCode(ESRCH):
    raiseOSError(osLastError())

proc closeInput(runtime: SupervisorRuntime) =
  if not runtime.inputClosed:
    closeFd(runtime.process.protocolWriteFd)
    runtime.process.protocolWriteFd = -1
    runtime.inputClosed = true

proc closeProtocolRead(runtime: SupervisorRuntime) =
  if runtime.process.protocolReadFd >= 0:
    closeFd(runtime.process.protocolReadFd)
    runtime.process.protocolReadFd = -1
  runtime.protocolEof = true

proc supervisorLogIdentity*(core: string): ProcessLogIdentity =
  ## stdout/stderr of the supervisor are logged as core:CORE/supervisor.
  ProcessLogIdentity(core: core, identity: "supervisor", kind: plSupervisor)

proc startSupervisor*(spec: ProcessSpec; reaper: Reaper; core, mode,
                      jumpstartVersion: string; nowMs,
                      readyTimeoutMs: int64): SupervisorRuntime =
  ## Spawns in the control cgroup described by `spec.cgroupProcs` (required:
  ## §15.1 rule 2), requests Linux child subreaper status before exec, and
  ## immediately writes the fd 3 hello. The caller hands stdoutFd/stderrFd to
  ## the logging manager (see `attachSupervisorLogging`).
  when not defined(linux):
    raise newException(OSError, "supervisor processes require Linux child subreapers")
  else:
    if spec.protocol and not spec.supervisorSubreaper:
      raise newException(ValueError, "supervisor must be a child subreaper")
    if spec.cgroupProcs.len == 0:
      raise newException(ValueError, "supervisor must start in the core's control/ cgroup")
    if reaper.isNil: raise newException(ValueError, "a central reaper is required")
    var supervisorSpec = spec
    supervisorSpec.protocol = true
    supervisorSpec.supervisorSubreaper = true
    result = SupervisorRuntime(
      model: initSupervisor(core, nowMs, readyTimeoutMs), reaper: reaper)
    let runtime = result
    try:
      result.process = spawn(supervisorSpec, reaper,
        owner = "core:" & core & "/supervisor",
        callback = proc(status: ChildStatus) = runtime.pendingExits.add status)
      setNonBlocking(result.process.protocolReadFd)
      writeAll(result.process.protocolWriteFd,
               result.model.helloLine(mode, jumpstartVersion))
    except:
      if result.process.pid > 0:
        result.closeInput()
        result.closeProtocolRead()
        discard reaper.signalChild(result.process.pid, SIGKILL)
      raise

proc attachSupervisorLogging*(runtime: SupervisorRuntime;
                              manager: CoreLoggingManager) =
  ## Transfers stdout/stderr ownership to the logging manager (§19.2).
  if runtime.isNil or manager.isNil: return
  if runtime.process.stdoutFd < 0 or runtime.process.stderrFd < 0: return
  manager.attachProcessPipes(runtime.process.stdoutFd, runtime.process.stderrFd,
                             supervisorLogIdentity(runtime.model.core))
  runtime.process.stdoutFd = -1
  runtime.process.stderrFd = -1

proc failProtocol(runtime: SupervisorRuntime; message: string;
                  kind = sreProtocolError): SupervisorRuntimeEvent =
  runtime.closeInput()
  runtime.closeProtocolRead()
  if not runtime.terminated:
    runtime.signalProcess(SIGTERM)
    runtime.terminated = true
  SupervisorRuntimeEvent(kind: kind, detail: message)

proc consumeLine(runtime: SupervisorRuntime; line: string;
                 nowMs: int64): SupervisorRuntimeEvent =
  if runtime.model.phase == spHandshaking:
    runtime.model.acceptHandshake(line, nowMs)
    return SupervisorRuntimeEvent(kind: sreReady)
  let disposition = runtime.model.receiveNotification(line, nowMs)
  case disposition
  of ndRateLimited:
    return SupervisorRuntimeEvent(kind: sreNotificationDropped,
      detail: "more than 100 notifications in one second")
  of ndFilesystemsReady:
    return SupervisorRuntimeEvent(kind: sreFilesystemsReady)
  of ndRecorded:
    # Parsing has already stored and validated it; decode once more only to
    # put the opaque unit name on the event returned to the caller.
    let node = parseJson(line)
    SupervisorRuntimeEvent(kind: sreNotification, unit: node["unit"].getStr,
                           detail: node["state"].getStr)

proc readAvailable(runtime: SupervisorRuntime; nowMs: int64): seq[SupervisorRuntimeEvent] =
  if runtime.protocolEof or runtime.process.protocolReadFd < 0: return
  var data: array[8192, char]
  # Like the adapter runtime, bound each pass: a supervisor that floods fd 4
  # cannot hold the daemon here. The descriptor stays readable, so the next
  # poll continues where this pass stopped.
  var passBytes = 0
  while passBytes < MaxReadPerPass:
    let count = posix.read(runtime.process.protocolReadFd, addr data[0], data.len)
    if count > 0:
      passBytes += int(count)
      for i in 0 ..< int(count): runtime.readBuffer.add data[i]
      if runtime.readBuffer.len > MaxExecLineBytes and '\n' notin runtime.readBuffer:
        result.add runtime.failProtocol("exec protocol line exceeds 1 MiB")
        return
      while true:
        let newline = runtime.readBuffer.find('\n')
        if newline < 0: break
        let line = runtime.readBuffer[0 .. newline]
        runtime.readBuffer.delete(0 .. newline)
        try:
          result.add runtime.consumeLine(line, nowMs)
        except SupervisorProtocolError as exc:
          result.add runtime.failProtocol(exc.msg)
          return
    elif count == 0:
      runtime.closeProtocolRead()
      return
    else:
      let error = osLastError()
      if error == OSErrorCode(EINTR): continue
      if error == OSErrorCode(EAGAIN) or error == OSErrorCode(EWOULDBLOCK): return
      result.add runtime.failProtocol(osErrorMsg(error))
      return

proc collectExits(runtime: SupervisorRuntime; core: var CoreRuntime): seq[SupervisorRuntimeEvent] =
  for status in runtime.pendingExits:
    let reason = case status.kind
      of cekExited: "supervisor exited with status " & $status.code
      of cekSignaled: "supervisor killed by signal " & $status.code
      else: "supervisor changed process state"
    let transition = runtime.model.observeExit(core, reason)
    runtime.exited = true
    runtime.exitStatus = status
    runtime.closeInput()
    runtime.closeProtocolRead()
    result.add SupervisorRuntimeEvent(kind: sreExited, status: status,
                                       transition: transition, detail: reason)
  runtime.pendingExits.setLen(0)

proc pumpSupervisor*(runtime: SupervisorRuntime; core: var CoreRuntime;
                     nowMs: int64): seq[SupervisorRuntimeEvent] =
  ## Non-blocking fd 4 reader plus delivery of statuses queued by Reaper.drain.
  ## An exit of a loaded core degrades it (§15.2 rule 4); it is never
  ## restarted.
  if runtime.isNil: return
  result.add runtime.readAvailable(nowMs)
  result.add runtime.collectExits(core)

proc advanceSupervisor*(runtime: SupervisorRuntime; core: var CoreRuntime;
                        nowMs: int64): seq[SupervisorRuntimeEvent] =
  ## Drives the handshake and unload deadlines without sleeping.
  if runtime.isNil: return
  result.add runtime.pumpSupervisor(core, nowMs)
  if runtime.model.handshakeExpired(nowMs) and not runtime.terminated:
    result.add runtime.failProtocol("supervisor handshake timed out",
                                    sreHandshakeTimeout)
  for action in runtime.model.continueUnload(nowMs):
    if action == saSendKill:
      runtime.signalProcess(SIGKILL)
  result.add runtime.collectExits(core)

proc unloadSupervisor*(runtime: SupervisorRuntime; nowMs: int64) =
  ## Invoke after the core shutdown operation. Escalation is performed by
  ## advanceSupervisor at the model's ten-second deadline.
  if runtime.isNil: return
  for action in runtime.model.beginUnload(nowMs):
    case action
    of saCloseDescriptor3: runtime.closeInput()
    of saSendTerm:
      runtime.signalProcess(SIGTERM)
      runtime.terminated = true
    of saSendKill: runtime.signalProcess(SIGKILL)

proc closeSupervisorRuntime*(runtime: SupervisorRuntime) =
  ## Descriptor cleanup for daemon teardown; does not reap or signal.
  if runtime.isNil: return
  runtime.closeInput()
  runtime.closeProtocolRead()
  closeFd(runtime.process.stdoutFd); runtime.process.stdoutFd = -1
  closeFd(runtime.process.stderrFd); runtime.process.stderrFd = -1

proc pumpReaper(reaper: Reaper) =
  if not reaper.isNil:
    if reaper.sigChldPending: discard reaper.drainWakeup()
    else: discard reaper.drain()

proc stopSupervisorBlocking*(runtime: SupervisorRuntime; core: var CoreRuntime;
                             clock: SupervisorClock; pause: SupervisorPause;
                             sink: SupervisorEventSink = nil): bool =
  ## §15.2 rule 5: close descriptor 3, SIGTERM, wait up to 10 seconds, SIGKILL.
  ## Pumps the central reaper while waiting. Returns true once the exit was
  ## observed. Used by unload step 5 and by load rollback.
  if runtime.isNil: return true
  if clock.isNil or pause.isNil:
    raise newException(ValueError, "supervisor stop requires a clock and pause")
  if runtime.exited: return true
  runtime.unloadSupervisor(clock())
  var killAt = 0'i64
  while true:
    runtime.reaper.pumpReaper()
    let now = clock()
    for event in runtime.advanceSupervisor(core, now):
      if not sink.isNil: sink(event)
    if runtime.exited: return true
    if runtime.model.killIssued:
      if killAt == 0: killAt = now
      elif now - killAt >= SupervisorReapGraceMs: return false
    pause(10)

proc awaitSupervisorReady*(runtime: SupervisorRuntime; clock: SupervisorClock;
                           pause: SupervisorPause;
                           sink: SupervisorEventSink = nil): CoreResult[bool] =
  ## Load step 7 (§20.3): wait for the supervisor's hello within ready_timeout.
  ## A timeout, a protocol error or an exit fails with E_INIT after the
  ## supervisor has been stopped (TERM, 10 s, KILL), so nothing is leaked.
  if runtime.isNil: return failure[bool](ecInit, "supervisor was not started")
  if clock.isNil or pause.isNil:
    return failure[bool](ecInit, "supervisor handshake requires a clock and pause")
  # The model's exit transition is computed on a scratch value: the
  # lifecycle executor owns the registry's state change for a failed load.
  var scratch = CoreRuntime(name: runtime.model.core, state: csLoading)
  var reason = ""
  var ready = false
  while reason.len == 0 and not ready:
    runtime.reaper.pumpReaper()
    for event in runtime.advanceSupervisor(scratch, clock()):
      if not sink.isNil: sink(event)
      if reason.len > 0: continue
      case event.kind
      of sreReady: ready = true
      of sreHandshakeTimeout: reason = "supervisor handshake timed out"
      of sreProtocolError: reason = "supervisor protocol error: " & event.detail
      of sreExited:
        reason = if ready: event.detail else: event.detail & " before completing its handshake"
      else: discard
    if reason.len == 0 and not ready: pause(5)
  if reason.len == 0: return success(true)
  discard runtime.stopSupervisorBlocking(scratch, clock, pause, sink)
  failure[bool](ecInit, reason)
