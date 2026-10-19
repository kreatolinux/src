import std/[monotimes, os, options, strutils, times, unittest]
import posix
import ../../../../jumpstart/cores/daemon/logging,
  ../../../../jumpstart/cores/backends/[supervisor, supervisor_runtime],
  ../../../../jumpstart/cores/manifest/types
import jumpstartcore/[errors, reaper, spawn]

proc kinds(events: seq[SupervisorRuntimeEvent]): seq[SupervisorRuntimeEventKind] =
  for event in events: result.add event.kind

const Hello = "printf '%s\\n' '{\"type\":\"hello\",\"protocol\":\"jumpstart-core/1\",\"role\":\"supervisor\"}' >&4; "

proc controlProcs(): string =
  ## Stand-in for control/cgroup.procs: spawn writes the PID into it.
  result = getTempDir() / ("jumpstart-sup-control-" & $getCurrentProcessId())
  writeFile(result, "")

proc controlFileFor(pid: Pid): string =
  getTempDir() / ("jumpstart-sup-control-" & $getCurrentProcessId())

proc spec(script: string): ProcessSpec =
  ProcessSpec(executable: "/bin/sh", arguments: @["-c", script],
    workingDirectory: "/", environment: buildSystemEnvironment(),
    cgroupProcs: controlProcs())

proc realClock(): SupervisorClock =
  let start = getMonoTime()
  result = proc(): int64 = (getMonoTime() - start).inMilliseconds

when defined(linux):
  proc eventsEventually(runtime: SupervisorRuntime; reaper: Reaper;
                        core: var CoreRuntime; wanted: SupervisorRuntimeEventKind;
                        startMs = 1'i64): seq[SupervisorRuntimeEvent] =
    for step in 0 .. 400:
      discard reaper.drain()
      let events = runtime.advanceSupervisor(core, startMs + step)
      result.add events
      if wanted in events.kinds: return
      sleep(5)

suite "supervisor process runtime":
  test "platform support is explicit":
    when not defined(linux):
      expect OSError:
        discard startSupervisor(spec("exit 0"), newReaper(), "demo", "system", "1", 0, 100)
    else:
      check compiles(startSupervisor(ProcessSpec(), newReaper(), "demo",
                                     "system", "1", 0, 100))

  when defined(linux):
    test "supervisors must start in the core's control cgroup":
      var noCgroup = spec("exit 0")
      noCgroup.cgroupProcs = ""
      expect ValueError:
        discard startSupervisor(noCgroup, newReaper(), "demo", "system", "1", 0, 100)

    test "fd3 handshake, fd4 notifications and filesystems-ready flow through the model":
      let reaper = newReaper()
      let script = "read hello <&3; " & Hello &
        "printf '%s\\n' '{\"type\":\"notify\",\"unit\":\"web.service\",\"state\":\"active\"}' >&4; " &
        "printf '%s\\n' '{\"type\":\"filesystems-ready\"}' >&4; " &
        "while read line <&3; do :; done"
      var core = CoreRuntime(name: "demo", state: csLoaded)
      let runtime = startSupervisor(spec(script), reaper, "demo", "system",
        "test", 0, 5_000)
      check readFile(runtime.process.pid.controlFileFor).strip == $runtime.process.pid
      let events = eventsEventually(runtime, reaper, core, sreFilesystemsReady)
      check sreReady in events.kinds
      check sreNotification in events.kinds
      check sreFilesystemsReady in events.kinds
      check runtime.model.lastKnown("web.service").isSome
      check runtime.model.lastKnown("web.service").get.state == rusActive
      runtime.unloadSupervisor(100)
      let exited = eventsEventually(runtime, reaper, core, sreExited, 101)
      check sreExited in exited.kinds
      check core.state == csLoaded
      runtime.closeSupervisorRuntime()

    test "unexpected process exit degrades a loaded core without a restart":
      let reaper = newReaper()
      let script = "read hello <&3; " & Hello & "exit 7"
      var core = CoreRuntime(name: "demo", state: csLoaded)
      let runtime = startSupervisor(spec(script), reaper, "demo", "system",
        "test", 0, 5_000)
      let events = eventsEventually(runtime, reaper, core, sreExited)
      check sreReady in events.kinds
      check sreExited in events.kinds
      check core.state == csDegraded
      check runtime.exited
      check reaper.registeredCount == 0   # nothing was started again
      runtime.closeSupervisorRuntime()

    test "a supervisor that misses its ready_timeout fails the load with E_INIT and is stopped":
      let reaper = newReaper()
      let runtime = startSupervisor(spec("read hello <&3; exec sleep 30"), reaper,
        "demo", "system", "test", 0, 150)
      let clock = realClock()
      let started = clock()
      let ready = awaitSupervisorReady(runtime, clock, proc(ms: int) = sleep(ms))
      check not ready.ok
      check ready.error.code == ecInit
      check "timed out" in ready.error.message
      check runtime.exited          # stopped (SIGTERM ended sleep) and reaped
      check clock() - started < 5_000
      runtime.closeSupervisorRuntime()

    test "a supervisor that exits before its hello fails the load":
      let reaper = newReaper()
      let runtime = startSupervisor(spec("exit 2"), reaper, "demo", "system",
        "test", 0, 5_000)
      let clock = realClock()
      let ready = awaitSupervisorReady(runtime, clock, proc(ms: int) = sleep(ms))
      check not ready.ok
      check ready.error.code == ecInit

    test "stop sends TERM, waits ten seconds, then KILL":
      let reaper = newReaper()
      let script = "trap '' TERM; read hello <&3; " & Hello &
        "while :; do sleep 0.05; done"
      let runtime = startSupervisor(spec(script), reaper, "demo", "system",
        "test", 0, 5_000)
      let base = realClock()
      check awaitSupervisorReady(runtime, base, proc(ms: int) = sleep(ms)).ok
      # Accelerated clock: every pause advances one second.
      var offset = 0'i64
      let fast: SupervisorClock = proc(): int64 = base() + offset
      var core = CoreRuntime(name: "demo", state: csUnloading)
      var seen: seq[SupervisorRuntimeEvent]
      check stopSupervisorBlocking(runtime, core, fast,
        proc(ms: int) =
          offset += 1_000
          sleep(ms),
        proc(event: SupervisorRuntimeEvent) = seen.add event)
      check runtime.model.killIssued
      check runtime.exitStatus.kind == cekSignaled
      check runtime.exitStatus.code == int(SIGKILL)
      check offset >= 10_000

    test "the supervisor is a child subreaper: services survive an adapter exit":
      let reaper = newReaper()
      let pidFile = getTempDir() / ("jumpstart-sup-svc-" & $getCurrentProcessId())
      removeFile(pidFile)
      # The supervisor starts a service through a short-lived intermediate (an
      # "adapter"), which exits at once. The service is orphaned and must be
      # reparented to the supervisor, not to Jumpstart.
      let script = "read hello <&3; " & Hello &
        "sh -c 'sleep 30 & echo $! > " & pidFile & "'; " &
        "while read line <&3; do :; done"
      var core = CoreRuntime(name: "demo", state: csLoaded)
      let runtime = startSupervisor(spec(script), reaper, "demo", "system",
        "test", 0, 5_000)
      discard eventsEventually(runtime, reaper, core, sreReady)
      for _ in 0 .. 200:
        if fileExists(pidFile) and readFile(pidFile).strip.len > 0: break
        sleep(10)
      let service = readFile(pidFile).strip
      sleep(50)
      let stat = readFile("/proc/" & service & "/stat")
      let ppid = stat[stat.rfind(')') + 2 .. ^1].splitWhitespace[1]
      check ppid == $runtime.process.pid
      check posix.kill(Pid(parseInt(service)), 0.cint) == 0
      discard posix.kill(Pid(parseInt(service)), SIGKILL)
      runtime.unloadSupervisor(100)
      discard eventsEventually(runtime, reaper, core, sreExited, 101)
      runtime.closeSupervisorRuntime()
      removeFile(pidFile)

    test "supervisor output is attached to the logging manager":
      let reaper = newReaper()
      var lines: seq[string]
      let logger = newCoreLogger(CoreLogConfig(path: "/dev/null",
        bufferCapacity: 4096, retrySeconds: 60, filesystemsReady: true),
        writer = proc(path, data: string) = lines.add(data),
        timestamp = proc(): string = "T")
      let manager = newCoreLoggingManager(logger)
      let script = "echo out; echo err >&2; read hello <&3; " & Hello &
        "while read line <&3; do :; done"
      var core = CoreRuntime(name: "demo", state: csLoaded)
      let runtime = startSupervisor(spec(script), reaper, "demo", "system",
        "test", 0, 5_000)
      runtime.attachSupervisorLogging(manager)
      discard eventsEventually(runtime, reaper, core, sreReady)
      for _ in 0 .. 100:
        discard manager.drainProcessPipes()
        if lines.len >= 2: break
        sleep(10)
      check "T info [core:demo/supervisor] out\n" in lines
      check "T warn [core:demo/supervisor] err\n" in lines
      runtime.unloadSupervisor(100)
      discard eventsEventually(runtime, reaper, core, sreExited, 101)
      manager.close()
