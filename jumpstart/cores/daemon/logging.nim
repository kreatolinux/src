## Injectable, per-daemon logging for Jumpstart cores (specification section 19.2).
## This module deliberately does not create state directories.
import std/[locks, monotimes, os, strutils, times]
import ../manifest/modes
when defined(posix):
  import std/oserrors

const
  EarlyLogCapacity* = 1024 * 1024
  LogRetrySeconds* = 60'i64

type
  CoreLogLevel* = enum clTrace, clDebug, clInfo, clWarn, clError, clFatal
  LogWriteProc* = proc(path, data: string) {.closure.}
  LogClockProc* = proc(): int64 {.closure.}
  LogTimestampProc* = proc(): string {.closure.}
  LogRotationHook* = proc(path: string) {.closure.}
  CoreLogConfig* = object
    path*: string
    bufferCapacity*: int
    retrySeconds*: int64
    filesystemsReady*: bool
  BufferedLogLine = object
    text: string
  CoreLogger* = ref object
    ## All writes, flushes, and rotation hooks are serialized by `lock`.
    path*: string
    minimumLevel*: CoreLogLevel
      ## Records below this level are discarded (default clTrace: keep all).
    bufferCapacity*: int
    retrySeconds*: int64
    filesystemsReady*: bool
    retryAt*: int64
    droppedLines*: uint64
    bufferedBytes*: int
    lines: seq[BufferedLogLine]
    writer: LogWriteProc
    clock: LogClockProc
    timestamp: LogTimestampProc
    beforeRotation, afterRotation: LogRotationHook
    lock: Lock

proc defaultClock(): int64 = getTime().toUnix
proc defaultTimestamp(): string = getTime().utc.format("yyyy-MM-dd'T'HH:mm:ss'.'fff'Z'")
proc appendFile(path, data: string) =
  let file = open(path, fmAppend)
  try:
    file.write(data)
    file.flushFile()
  finally: file.close()

proc defaultCoreLogConfig*(path: string): CoreLogConfig =
  CoreLogConfig(path: path, bufferCapacity: EarlyLogCapacity,
                retrySeconds: LogRetrySeconds, filesystemsReady: false)

proc newCoreLogger*(config: CoreLogConfig; writer: LogWriteProc = nil;
                    clock: LogClockProc = nil;
                    timestamp: LogTimestampProc = nil;
                    beforeRotation: LogRotationHook = nil;
                    afterRotation: LogRotationHook = nil): CoreLogger =
  if config.path.len == 0: raise newException(ValueError, "log path must not be empty")
  if config.bufferCapacity < 1: raise newException(ValueError, "log buffer capacity must be positive")
  if config.retrySeconds < 1: raise newException(ValueError, "log retry interval must be positive")
  new(result)
  result.path = config.path
  result.bufferCapacity = config.bufferCapacity
  result.retrySeconds = config.retrySeconds
  result.filesystemsReady = config.filesystemsReady
  result.writer = if writer.isNil: appendFile else: writer
  result.clock = if clock.isNil: defaultClock else: clock
  result.timestamp = if timestamp.isNil: defaultTimestamp else: timestamp
  result.beforeRotation = beforeRotation
  result.afterRotation = afterRotation
  initLock(result.lock)

proc close*(logger: CoreLogger) =
  ## A logger must no longer be used after close.
  if not logger.isNil: deinitLock(logger.lock)

proc levelName*(level: CoreLogLevel): string =
  case level
  of clTrace: "trace"
  of clDebug: "debug"
  of clInfo: "info"
  of clWarn: "warn"
  of clError: "error"
  of clFatal: "fatal"

proc oneLine(value: string): string =
  result = value.replace("\\", "\\\\").replace("\r", "\\r").replace("\n", "\\n")

proc formatLogLine*(timestamp: string; level: CoreLogLevel;
                    source, message: string): string =
  if timestamp.len == 0: raise newException(ValueError, "timestamp is required")
  if source.len == 0: raise newException(ValueError, "log source is required")
  oneLine(timestamp) & " " & level.levelName & " [" & oneLine(source) & "] " &
    oneLine(message) & "\n"

proc droppedMarker(logger: CoreLogger): string =
  logger.timestamp() & " warn [jumpstart] early log buffer dropped " &
    $logger.droppedLines & " line(s)\n"

proc trimFor(logger: CoreLogger; extraBytes: int) =
  while logger.lines.len > 0 and logger.bufferedBytes + extraBytes > logger.bufferCapacity:
    logger.bufferedBytes -= logger.lines[0].text.len
    logger.lines.delete(0)
    inc logger.droppedLines
  if logger.droppedLines > 0:
    var markerLen = logger.droppedMarker.len
    while logger.lines.len > 0 and
        logger.bufferedBytes + extraBytes + markerLen > logger.bufferCapacity:
      logger.bufferedBytes -= logger.lines[0].text.len
      logger.lines.delete(0)
      inc logger.droppedLines
      markerLen = logger.droppedMarker.len

proc bufferLine(logger: CoreLogger; line: string) =
  logger.trimFor(line.len)
  let markerLen = if logger.droppedLines == 0: 0 else: logger.droppedMarker.len
  if line.len + markerLen > logger.bufferCapacity:
    inc logger.droppedLines
    logger.trimFor(0)
    return
  logger.lines.add BufferedLogLine(text: line)
  logger.bufferedBytes += line.len

proc bufferedPayload(logger: CoreLogger): string =
  if logger.droppedLines > 0: result.add(logger.droppedMarker)
  for line in logger.lines: result.add(line.text)
proc scheduleRetry(logger: CoreLogger) = logger.retryAt = logger.clock() + logger.retrySeconds

proc flushUnlocked(logger: CoreLogger): bool =
  if not logger.filesystemsReady: return false
  let payload = logger.bufferedPayload
  if payload.len == 0:
    logger.retryAt = 0
    return true
  try:
    logger.writer(logger.path, payload)
    logger.lines.setLen(0)
    logger.bufferedBytes = 0
    logger.droppedLines = 0
    logger.retryAt = 0
    true
  except CatchableError:
    logger.scheduleRetry()
    false

proc flush*(logger: CoreLogger): bool =
  withLock logger.lock: result = logger.flushUnlocked()
proc setFilesystemsReady*(logger: CoreLogger; ready = true): bool =
  withLock logger.lock:
    logger.filesystemsReady = ready
    if ready: result = logger.flushUnlocked() else: result = true
proc retryDue*(logger: CoreLogger; now: int64): bool =
  withLock logger.lock:
    result = logger.filesystemsReady and logger.retryAt != 0 and now >= logger.retryAt
proc retry*(logger: CoreLogger; now: int64): bool =
  withLock logger.lock:
    if logger.retryAt == 0 or now < logger.retryAt: return false
    result = logger.flushUnlocked()
proc retry*(logger: CoreLogger): bool = logger.retry(logger.clock())

proc emitLine(logger: CoreLogger; line: string) =
  withLock logger.lock:
    if not logger.filesystemsReady or logger.retryAt != 0:
      logger.bufferLine(line)
      return
    try: logger.writer(logger.path, line)
    except CatchableError:
      logger.bufferLine(line)
      logger.scheduleRetry()

proc log*(logger: CoreLogger; level: CoreLogLevel; source, message: string) =
  if level < logger.minimumLevel: return
  logger.emitLine(formatLogLine(logger.timestamp(), level, source, message))
proc coreSource*(core: string): string = "core:" & core
proc supervisorSource*(core: string): string = core.coreSource & "/supervisor"
proc adapterSource*(core, adapter: string): string = core.coreSource & "/adapter:" & adapter
proc logCore*(logger: CoreLogger; level: CoreLogLevel; core, message: string) =
  logger.log(level, core.coreSource, message)

proc logProcessOutput*(logger: CoreLogger; core, identity, output: string;
                       stderr = false; longLivedKind = "") =
  var source: string
  case longLivedKind
  of "": source = core.coreSource & "/request:" & identity
  of "supervisor": source = core.supervisorSource
  of "adapter": source = core.adapterSource(identity)
  else: raise newException(ValueError, "unknown long-lived process kind")
  logger.log(if stderr: clWarn else: clInfo, source, output)

proc operationStart*(logger: CoreLogger; core, requestId, operation, unit,
                     backend: string) =
  logger.logCore(clInfo, core, "request_id=" & oneLine(requestId) &
    " event=start operation=" & oneLine(operation) & " unit=" & oneLine(unit) &
    " backend=" & oneLine(backend) & " duration_ms=0 result=started")
proc operationComplete*(logger: CoreLogger; level: CoreLogLevel; core,
                        requestId, operation, unit, backend: string;
                        durationMs: int64; resultCode: string) =
  logger.logCore(level, core, "request_id=" & oneLine(requestId) &
    " event=complete operation=" & oneLine(operation) & " unit=" & oneLine(unit) &
    " backend=" & oneLine(backend) & " duration_ms=" & $durationMs &
    " result=" & oneLine(resultCode))

proc rotate*(logger: CoreLogger): bool =
  ## Hooks run under the write lock; policy (rename/truncate/reopen) is injected.
  withLock logger.lock:
    try:
      if not logger.beforeRotation.isNil: logger.beforeRotation(logger.path)
      if not logger.afterRotation.isNil: logger.afterRotation(logger.path)
      if logger.filesystemsReady and logger.retryAt == 0:
        result = logger.flushUnlocked()
      else: result = true
    except CatchableError:
      logger.scheduleRetry()
      result = false

proc bufferedLineCount*(logger: CoreLogger): int =
  withLock logger.lock: result = logger.lines.len
proc bufferedByteCount*(logger: CoreLogger): int =
  withLock logger.lock:
    result = logger.bufferedBytes
    if logger.droppedLines > 0: result += logger.droppedMarker.len
proc droppedLineCount*(logger: CoreLogger): uint64 =
  withLock logger.lock: result = logger.droppedLines
proc nextRetryAt*(logger: CoreLogger): int64 =
  withLock logger.lock: result = logger.retryAt

# Runtime-facing manager -----------------------------------------------------
# The daemon's event loop owns this object. CoreLogger itself remains safe for
# concurrent producers; pipe registration/draining is intentionally explicit.
when defined(posix):
  import std/posix

const
  ProcessLogLineLimit* = 64 * 1024
  MaxDrainBytesPerPipe = 256 * 1024
    ## One pipe is read at most this much per drain, so a process that floods
    ## its output cannot hold the event loop (the rest waits for the next turn).

type
  ProcessLogKind* = enum
    plRequest, plSupervisor, plAdapter

  ProcessLogIdentity* = object
    core*: string
    identity*: string
    kind*: ProcessLogKind

  ManagedLogPipe = object
    fd: cint
    identity: ProcessLogIdentity
    stderr: bool
    pending: string

  CoreLoggingManager* = ref object
    logger*: CoreLogger
    pipes: seq[ManagedLogPipe]

proc newCoreLoggingManager*(logger: CoreLogger): CoreLoggingManager =
  if logger.isNil: raise newException(ValueError, "logger is required")
  CoreLoggingManager(logger: logger)

proc source(identity: ProcessLogIdentity): string =
  case identity.kind
  of plRequest: identity.core.coreSource & "/request:" & identity.identity
  of plSupervisor: identity.core.supervisorSource
  of plAdapter: identity.core.adapterSource(identity.identity)

proc emitProcessLine(manager: CoreLoggingManager; pipe: ManagedLogPipe;
                     line: string) =
  manager.logger.log(if pipe.stderr: clWarn else: clInfo,
                     pipe.identity.source, line)

when defined(posix):
  proc setNonBlocking(fd: cint) =
    let flags = fcntl(fd, F_GETFL, 0)
    if flags < 0 or fcntl(fd, F_SETFL, flags or O_NONBLOCK) < 0:
      raiseOSError(osLastError())

  proc attachProcessPipe*(manager: CoreLoggingManager; fd: cint;
                          identity: ProcessLogIdentity; stderr = false) =
    ## Takes ownership of fd and makes it non-blocking. The fd is closed at EOF,
    ## by detachAllPipes, or by close(manager).
    if manager.isNil or manager.logger.isNil:
      raise newException(ValueError, "logging manager is required")
    if fd < 0: raise newException(ValueError, "invalid process pipe")
    if identity.core.len == 0 or identity.identity.len == 0:
      raise newException(ValueError, "process log identity is incomplete")
    for item in manager.pipes:
      if item.fd == fd: raise newException(ValueError, "process pipe is already attached")
    setNonBlocking(fd)
    manager.pipes.add ManagedLogPipe(fd: fd, identity: identity, stderr: stderr)

  proc attachProcessPipes*(manager: CoreLoggingManager; stdoutFd, stderrFd: cint;
                           identity: ProcessLogIdentity) =
    ## Takes ownership of both descriptors. Roll back stdout if stderr setup
    ## fails, so callers never have ambiguous ownership.
    manager.attachProcessPipe(stdoutFd, identity, false)
    try:
      manager.attachProcessPipe(stderrFd, identity, true)
    except:
      discard posix.close(stdoutFd)
      manager.pipes.setLen(manager.pipes.len - 1)
      raise

  proc emitCompleteLines(manager: CoreLoggingManager; pipe: var ManagedLogPipe): int =
    while true:
      let newline = pipe.pending.find('\n')
      if newline < 0:
        while pipe.pending.len >= ProcessLogLineLimit:
          manager.emitProcessLine(pipe, pipe.pending[0 ..< ProcessLogLineLimit])
          pipe.pending.delete(0 ..< ProcessLogLineLimit)
          inc result
        break
      var line = pipe.pending[0 ..< newline]
      pipe.pending.delete(0 .. newline)
      if line.len > 0 and line[^1] == '\r': line.setLen(line.len - 1)
      manager.emitProcessLine(pipe, line)
      inc result

  proc drainProcessPipes*(manager: CoreLoggingManager): int =
    ## Drain all bytes currently available without blocking. Returns the number
    ## of records emitted. EOF emits a final unterminated line and closes the fd.
    if manager.isNil: return 0
    var i = 0
    var chunk: array[8192, char]
    while i < manager.pipes.len:
      var eof = false
      var readBytes = 0
      while readBytes < MaxDrainBytesPerPipe:
        let count = posix.read(manager.pipes[i].fd, addr chunk[0], chunk.len)
        if count > 0:
          readBytes += int(count)
          for j in 0 ..< int(count): manager.pipes[i].pending.add(chunk[j])
          result += manager.emitCompleteLines(manager.pipes[i])
        elif count == 0:
          eof = true
          break
        else:
          let error = osLastError()
          if error == OSErrorCode(EINTR): continue
          if error == OSErrorCode(EAGAIN) or error == OSErrorCode(EWOULDBLOCK): break
          eof = true
          manager.logger.log(clWarn, manager.pipes[i].identity.source,
            "process output read failed: " & $error)
          inc result
          break
      if eof:
        if manager.pipes[i].pending.len > 0:
          manager.emitProcessLine(manager.pipes[i], manager.pipes[i].pending)
          inc result
        discard posix.close(manager.pipes[i].fd)
        manager.pipes.delete(i)
      else:
        inc i

  proc detachAllPipes*(manager: CoreLoggingManager) =
    if manager.isNil: return
    for pipe in manager.pipes: discard posix.close(pipe.fd)
    manager.pipes.setLen(0)

else:
  proc attachProcessPipe*(manager: CoreLoggingManager; fd: cint;
                          identity: ProcessLogIdentity; stderr = false) =
    raise newException(OSError, "process pipe logging requires POSIX")
  proc attachProcessPipes*(manager: CoreLoggingManager; stdoutFd, stderrFd: cint;
                           identity: ProcessLogIdentity) =
    raise newException(OSError, "process pipe logging requires POSIX")
  proc drainProcessPipes*(manager: CoreLoggingManager): int = 0
  proc detachAllPipes*(manager: CoreLoggingManager) = discard

proc filesystemsReady*(manager: CoreLoggingManager): bool =
  ## Lifecycle hook for §20.2: transitions logging and flushes early records.
  manager.logger.setFilesystemsReady(true)

proc loggingTick*(manager: CoreLoggingManager; now: int64): bool =
  ## Event-loop hook: drains child output and performs a due file retry.
  discard manager.drainProcessPipes()
  if manager.logger.retryDue(now): return manager.logger.retry(now)
  true

proc loggingTick*(manager: CoreLoggingManager): bool =
  discard manager.drainProcessPipes()
  if manager.logger.retryDue(manager.logger.clock()): return manager.logger.retry()
  true

proc rotateLog*(manager: CoreLoggingManager): bool = manager.logger.rotate()

proc close*(manager: CoreLoggingManager) =
  ## Closes owned process pipes, then the underlying logger lock.
  if manager.isNil: return
  manager.detachAllPipes()
  manager.logger.close()

proc attachedPipeCount*(manager: CoreLoggingManager): int =
  if manager.isNil: 0 else: manager.pipes.len

# Production construction ----------------------------------------------------

proc daemonLogPath*(paths: CorePaths): string =
  ## §7.2/§19.2: /var/log/jumpstart.log in system mode and
  ## ~/.local/state/jumpstart/jumpstart.log in user mode. Never the system
  ## path for a user daemon.
  if paths.logPath.len == 0 or not paths.logPath.isAbsolute:
    raise newException(ValueError, "mode paths carry no absolute log path")
  case paths.mode
  of cmSystem: paths.logPath
  of cmUser:
    if paths.home.len == 0 or not paths.logPath.startsWith(paths.home & "/"):
      raise newException(ValueError, "user log path must be inside the user's home")
    paths.logPath

when defined(posix):
  var oNoFollow {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint
  proc openAppend(path: string; mode: int): cint =
    result = posix.open(path.cstring, O_WRONLY or O_APPEND or O_CREAT or
                        O_CLOEXEC or oNoFollow, Mode(mode))
    if result < 0: raiseOSError(osLastError(), path)

  proc productionWriter*(mode: CoreMode): LogWriteProc =
    ## Appends with O_APPEND|O_NOFOLLOW. System log files are created 0640,
    ## user log files 0600. In user mode the private parent directory
    ## (~/.local/state/jumpstart, 0700) is created when missing; the system
    ## daemon never creates directories for its log (it only writes once
    ## filesystems are ready, §20.2).
    let fileMode = if mode == cmSystem: 0o640 else: 0o600
    result = proc(path, data: string) =
      if mode == cmUser:
        let parent = parentDir(path)
        if not dirExists(parent):
          createDir(parent)
          if posix.chmod(parent.cstring, Mode(0o700)) != 0:
            raiseOSError(osLastError(), parent)
      let fd = openAppend(path, fileMode)
      defer: discard posix.close(fd)
      var offset = 0
      while offset < data.len:
        let n = posix.write(fd, unsafeAddr data[offset], data.len - offset)
        if n > 0: offset += int(n)
        elif n < 0 and osLastError() == OSErrorCode(EINTR): discard
        else: raiseOSError(osLastError(), path)

proc newDaemonLogger*(paths: CorePaths; minimumLevel = clInfo;
                      writer: LogWriteProc = nil;
                      clock: LogClockProc = nil;
                      timestamp: LogTimestampProc = nil): CoreLogger =
  ## The daemon's production logger. System mode starts buffering (1 MiB ring)
  ## until `setFilesystemsReady`; user mode is always ready (§20.2).
  var config = defaultCoreLogConfig(daemonLogPath(paths))
  config.filesystemsReady = paths.mode == cmUser
  var actualWriter = writer
  when defined(posix):
    if actualWriter.isNil: actualWriter = productionWriter(paths.mode)
  result = newCoreLogger(config, actualWriter, clock, timestamp)
  result.minimumLevel = minimumLevel

type
  OperationLogScope* = object
    ## One operation's start/completion pair (§19.2).
    core*, requestId*, operation*, unit*, backend*: string
    started: MonoTime

proc beginOperation*(logger: CoreLogger; core, requestId, operation, unit,
                     backend: string): OperationLogScope =
  logger.operationStart(core, requestId, operation, unit, backend)
  OperationLogScope(core: core, requestId: requestId, operation: operation,
                    unit: unit, backend: backend, started: getMonoTime())

proc finishOperation*(logger: CoreLogger; scope: OperationLogScope;
                      resultCode: string) =
  ## `resultCode` is "ok" or the error name (E_*). Failures log at warn.
  let elapsed = (getMonoTime() - scope.started).inMilliseconds
  logger.operationComplete(if resultCode == "ok": clInfo else: clWarn,
    scope.core, scope.requestId, scope.operation, scope.unit, scope.backend,
    elapsed, resultCode)

proc requestLogIdentity*(core, requestId: string): ProcessLogIdentity =
  ## Output of a per-request process (runner, oneshot adapter).
  ProcessLogIdentity(core: core, identity: requestId, kind: plRequest)

proc adapterLogIdentity*(core, adapter: string): ProcessLogIdentity =
  ProcessLogIdentity(core: core, identity: adapter, kind: plAdapter)
