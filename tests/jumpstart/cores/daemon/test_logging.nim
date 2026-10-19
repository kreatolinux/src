import std/[strutils, unittest]
import ../../../../jumpstart/cores/daemon/logging

suite "per-core logging":
  test "format and source helpers produce one physical line":
    check formatLogLine("T", clWarn, "core:demo", "bad\nnews") ==
      "T warn [core:demo] bad\\nnews\n"
    check supervisorSource("demo") == "core:demo/supervisor"
    check adapterSource("demo", "main") == "core:demo/adapter:main"

  test "early lines flush in order once filesystems are ready":
    var writes: seq[string]
    let logger = newCoreLogger(defaultCoreLogConfig("/injected/log"),
      writer = proc(path, data: string) = writes.add(path & ":" & data),
      timestamp = proc(): string = "T")
    defer: logger.close()
    logger.logCore(clInfo, "a", "one")
    logger.logCore(clWarn, "b", "two")
    check writes.len == 0
    check logger.bufferedLineCount == 2
    check logger.setFilesystemsReady()
    check writes == @["/injected/log:T info [core:a] one\nT warn [core:b] two\n"]
    check logger.bufferedByteCount == 0

  test "bounded ring drops oldest lines and emits one marker":
    var config = defaultCoreLogConfig("memory")
    config.bufferCapacity = 100
    var written = ""
    let logger = newCoreLogger(config,
      writer = proc(path, data: string) = written.add(data),
      timestamp = proc(): string = "T")
    defer: logger.close()
    for i in 0 .. 9: logger.logCore(clInfo, "x", "message-" & $i)
    check logger.bufferedByteCount <= config.bufferCapacity
    check logger.droppedLineCount > 0
    check logger.setFilesystemsReady()
    check written.count("early log buffer dropped") == 1
    check "message-9" in written
    check "message-0" notin written

  test "write failures buffer and retries respect injected clock":
    var now = 10'i64
    var fail = true
    var attempts = 0
    var written = ""
    var config = defaultCoreLogConfig("memory")
    config.filesystemsReady = true
    let logger = newCoreLogger(config,
      writer = proc(path, data: string) =
        inc attempts
        if fail: raise newException(IOError, "unavailable")
        written.add(data),
      clock = proc(): int64 = now,
      timestamp = proc(): string = "T")
    defer: logger.close()
    logger.logCore(clInfo, "demo", "first")
    logger.logCore(clInfo, "demo", "second")
    check attempts == 1
    check logger.nextRetryAt == 70
    check not logger.retry(69)
    check attempts == 1
    fail = false
    check logger.retry(70)
    check attempts == 2
    check "first" in written and "second" in written
    check logger.nextRetryAt == 0

  test "operation and process helpers carry required context and levels":
    var written = ""
    var config = defaultCoreLogConfig("memory")
    config.filesystemsReady = true
    let logger = newCoreLogger(config,
      writer = proc(path, data: string) = written.add(data),
      timestamp = proc(): string = "T")
    defer: logger.close()
    logger.operationStart("demo", "r1", "service.start", "sshd", "exec")
    logger.operationComplete(clInfo, "demo", "r1", "service.start", "sshd",
                             "exec", 42, "OK")
    logger.logProcessOutput("demo", "r1", "hello", stderr = false)
    logger.logProcessOutput("demo", "main", "oops", stderr = true,
                            longLivedKind = "adapter")
    check "request_id=r1 event=start operation=service.start unit=sshd backend=exec" in written
    check "event=complete" in written and "duration_ms=42 result=OK" in written
    check "info [core:demo/request:r1] hello" in written
    check "warn [core:demo/adapter:main] oops" in written

  test "rotation hooks are ordered and hook failures enter retry state":
    var events: seq[string]
    var now = 5'i64
    var config = defaultCoreLogConfig("memory")
    config.filesystemsReady = true
    let logger = newCoreLogger(config,
      writer = proc(path, data: string) = events.add("write"),
      clock = proc(): int64 = now,
      beforeRotation = proc(path: string) = events.add("before"),
      afterRotation = proc(path: string) = events.add("after"))
    defer: logger.close()
    check logger.rotate()
    check events == @["before", "after"]

    let failed = newCoreLogger(config,
      writer = proc(path, data: string) = discard,
      clock = proc(): int64 = now,
      beforeRotation = proc(path: string) = raise newException(IOError, "no"))
    defer: failed.close()
    check not failed.rotate()
    check failed.nextRetryAt == 65

when defined(posix):
  import std/[os, posix]

  proc writeFd(fd: cint; value: string) =
    var offset = 0
    while offset < value.len:
      let count = posix.write(fd, unsafeAddr value[offset], value.len - offset)
      if count < 0: raiseOSError(osLastError())
      offset += int(count)

  test "manager consumes stdout and stderr pipes with stream boundaries":
    var output = ""
    var config = defaultCoreLogConfig("memory")
    config.filesystemsReady = true
    let logger = newCoreLogger(config,
      writer = proc(path, data: string) = output.add(data),
      timestamp = proc(): string = "T")
    let manager = newCoreLoggingManager(logger)
    defer: manager.close()
    var stdoutPipe, stderrPipe: array[2, cint]
    check posix.pipe(stdoutPipe) == 0
    check posix.pipe(stderrPipe) == 0
    manager.attachProcessPipes(stdoutPipe[0], stderrPipe[0],
      ProcessLogIdentity(core: "demo", identity: "req-1", kind: plRequest))
    writeFd(stdoutPipe[1], "one\ntwo")
    writeFd(stderrPipe[1], "bad\n")
    discard posix.close(stdoutPipe[1])
    discard posix.close(stderrPipe[1])
    check manager.drainProcessPipes() == 3
    check manager.attachedPipeCount == 0
    check "info [core:demo/request:req-1] one" in output
    check "info [core:demo/request:req-1] two" in output
    check "warn [core:demo/request:req-1] bad" in output

  test "manager lifecycle flushes early records and exposes rotation":
    var writes: seq[string]
    var rotations: seq[string]
    let logger = newCoreLogger(defaultCoreLogConfig("/runtime/user.log"),
      writer = proc(path, data: string) = writes.add(path & ":" & data),
      timestamp = proc(): string = "T",
      beforeRotation = proc(path: string) = rotations.add("before:" & path),
      afterRotation = proc(path: string) = rotations.add("after:" & path))
    let manager = newCoreLoggingManager(logger)
    defer: manager.close()
    logger.logCore(clInfo, "demo", "early")
    check writes.len == 0
    check manager.filesystemsReady()
    check writes == @["/runtime/user.log:T info [core:demo] early\n"]
    check manager.rotateLog()
    check rotations == @["before:/runtime/user.log", "after:/runtime/user.log"]

import std/os
import posix
import ../../../../jumpstart/cores/manifest/modes

suite "production daemon logger":
  test "each mode logs to its own path; user mode never uses the system log":
    let system = pathsFor(cmSystem, 0)
    check daemonLogPath(system) == "/var/log/jumpstart.log"
    let user = pathsFor(cmUser, 1000, "/home/alice")
    check daemonLogPath(user) == "/home/alice/.local/state/jumpstart/jumpstart.log"
    var forged = user
    forged.logPath = "/var/log/jumpstart.log"
    expect ValueError: discard daemonLogPath(forged)

  test "user mode writes at once into a private file and directory":
    let home = getTempDir() / ("jumpstart-loghome-" & $getCurrentProcessId())
    if dirExists(home): removeDir(home)
    createDir(home)
    defer: removeDir(home)
    let logger = newDaemonLogger(pathsFor(cmUser, 1000, home),
                                 timestamp = proc(): string = "T")
    defer: logger.close()
    logger.logCore(clInfo, "demo", "hello")
    logger.log(clDebug, "jumpstart", "filtered")
    let path = home / ".local/state/jumpstart/jumpstart.log"
    check readFile(path) == "T info [core:demo] hello\n"
    var st: Stat
    check stat(path.cstring, st) == 0 and (st.st_mode and Mode(0o777)) == Mode(0o600)
    check stat(parentDir(path).cstring, st) == 0 and
      (st.st_mode and Mode(0o777)) == Mode(0o700)

  test "system mode buffers until filesystems are ready":
    var writes: seq[string]
    let logger = newDaemonLogger(pathsFor(cmSystem, 0),
      writer = proc(path, data: string) = writes.add(path & ":" & data),
      timestamp = proc(): string = "T")
    defer: logger.close()
    logger.logCore(clInfo, "demo", "early")
    check writes.len == 0
    check logger.setFilesystemsReady()
    check writes == @["/var/log/jumpstart.log:T info [core:demo] early\n"]

  test "operations log one start and one completion line with duration and result":
    var text = ""
    let logger = newCoreLogger(CoreLogConfig(path: "x", bufferCapacity: 4096,
      retrySeconds: 60, filesystemsReady: true),
      writer = proc(path, data: string) = text.add(data),
      timestamp = proc(): string = "T")
    defer: logger.close()
    let scope = logger.beginOperation("demo", "r1", "service.start", "web", "exec")
    logger.finishOperation(scope, "E_TIMEOUT")
    let lines = text.splitLines
    check lines[0].startsWith("T info [core:demo] request_id=r1 event=start operation=service.start unit=web backend=exec")
    check lines[1].startsWith("T warn [core:demo] request_id=r1 event=complete operation=service.start unit=web backend=exec duration_ms=")
    check lines[1].endsWith("result=E_TIMEOUT")
    check requestLogIdentity("demo", "r1").kind == plRequest
    check adapterLogIdentity("demo", "main").kind == plAdapter
