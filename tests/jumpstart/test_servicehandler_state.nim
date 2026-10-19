## serviceHandler runtime state: exit attribution and reaper-driven exits.
import std/[os, posix, strutils, tables, times, unittest]
import ../../jumpstart/serviceHandler/[globalVariables, start, stop, status]
import jumpstartcore/errors

proc newContext(label: string): NativeContext =
  let root = getTempDir() / ("jumpstart-sh-state-" & label & "-" &
    $getCurrentProcessId() & "-" & $int(epochTime() * 1000))
  createDir(root / "etc")
  newNativeContext(root / "etc", root / "run", newReaper(), stopTimeoutMs = 3000)

proc decfile(ctx: NativeContext; name, body: string) =
  writeFile(ctx.configRoot / (name & ".kg"), body)

suite "serviceHandler lifecycle state":
  test "unknown services have no record":
    let ctx = newContext("lookup")
    defer: removeDir(parentDir(ctx.configRoot))
    check ctx.findService("missing").isNil
    check not ctx.isRunning("missing")

  test "requested stop attribution can be recorded and reset":
    let ctx = newContext("attribution")
    defer: removeDir(parentDir(ctx.configRoot))
    check not ctx.lastServiceExitWasRequested("demo")
    ctx.recordServiceExit("demo", true)
    check ctx.lastServiceExitWasRequested("demo")
    ctx.clearServiceExit("demo")
    check not ctx.lastServiceExitWasRequested("demo")

  test "shell exit codes match the historical status files":
    check shellExitCode(decodeStatus(1, 3 shl 8)) == 3
    check shellExitCode(decodeStatus(1, cint(SIGTERM))) == 143

  test "exits are delivered by the reaper and recorded with attribution":
    let ctx = newContext("reaper")
    defer: removeDir(parentDir(ctx.configRoot))
    ctx.decfile("web", "description: \"w\"\ntype: \"simple\"\nservice {\n  exec \"sleep 30\"\n}\n")
    ctx.startService("web")
    let record = ctx.findService("web")
    check record.running
    check readFile(ctx.serviceStateDir("web") / "status") == "running"
    ctx.stopService("web")
    check not record.running
    check record.requestedStop
    check ctx.lastServiceExitWasRequested("web")
    check readFile(ctx.serviceStateDir("web") / "status") == "stopped with an exit code 143"
    # The status file of a stopped service never blocks the next start.
    ctx.startService("web")
    check ctx.isRunning("web")
    check not ctx.lastServiceExitWasRequested("web")
    ctx.stopService("web")

  test "a service ignoring SIGTERM is killed after the grace period":
    let ctx = newContext("sigkill")
    ctx.stopTimeoutMs = 300
    defer: removeDir(parentDir(ctx.configRoot))
    ctx.decfile("stubborn", "description: \"s\"\ntype: \"simple\"\nservice {\n" &
      "  exec \"sh -c 'trap \\\"\\\" TERM; while true; do sleep 1; done'\"\n}\n")
    ctx.startService("stubborn")
    sleep(200) # let the shell install its trap
    ctx.stopService("stubborn")
    check not ctx.isRunning("stubborn")
    check ctx.findService("stubborn").exitCode == 137

  test "execPre runs to completion through the reaper before exec":
    let ctx = newContext("pre")
    defer: removeDir(parentDir(ctx.configRoot))
    let marker = parentDir(ctx.configRoot) / "pre-ran"
    ctx.decfile("web", "description: \"w\"\ntype: \"simple\"\nservice {\n" &
      "  exec_pre \"touch " & marker & "\"\n  exec \"sleep 30\"\n}\n")
    ctx.startService("web")
    check fileExists(marker)
    check ctx.reaper.registeredCount == 1 # only the main process remains
    ctx.stopService("web")

  test "a hung execPre is killed at its timeout and the start fails":
    let ctx = newContext("pre-hung")
    ctx.execPreTimeoutMs = 300
    defer: removeDir(parentDir(ctx.configRoot))
    ctx.decfile("hung", "description: \"h\"\ntype: \"simple\"\nservice {\n" &
      "  exec_pre \"sleep 30\"\n  exec \"sleep 30\"\n}\n")
    let began = epochTime()
    expect CoreError:
      ctx.startService("hung")
    check epochTime() - began < 5.0
    check not ctx.isRunning("hung")
    check ctx.reaper.registeredCount == 0 # the pre-command was killed and reaped

  test "waitUntil counts wall time, including time spent pumping":
    let ctx = newContext("wall")
    defer: removeDir(parentDir(ctx.configRoot))
    ctx.pump = proc() = sleep(60)
    let began = epochTime()
    check not ctx.waitUntil(proc(): bool = false, 200)
    # A count of 5 ms sleeps would take 40 pump passes (about 2.6 s).
    check epochTime() - began < 1.0

  test "commands resolve through the unit environment PATH":
    let line = resolveCommand("sh -c 'exit 3'", [("PATH", "/usr/bin:/bin")])
    check line.executable.endsWith("/sh")
    check line.arguments == @["-c", "exit 3"]
    expect OSError:
      discard resolveCommand("no-such-binary-jumpstart", [("PATH", "/usr/bin:/bin")])
    expect ValueError:
      discard resolveCommand("   ", [("PATH", "/bin")])

  test "signals parse by name, SIG name and number":
    check parseSignal("HUP") == SIGHUP
    check parseSignal("SIGTERM") == SIGTERM
    check parseSignal("sigkill") == SIGKILL
    check parseSignal($int(SIGUSR1)) == SIGUSR1
    for bad in ["", "0", "65", "BOGUS", "-1"]:
      try:
        discard parseSignal(bad)
        check false
      except CoreError as e:
        check e.code == ecUsage

  test "terminal services stay in the daemon's process group; others do not":
    let ctx = newContext("terminal")
    defer: removeDir(parentDir(ctx.configRoot))
    ctx.decfile("getty", "description: \"g\"\ntype: \"simple\"\nservice {\n" &
      "  terminal true\n  exec \"sleep 30\"\n}\n")
    ctx.decfile("daemon", "description: \"d\"\ntype: \"simple\"\nservice {\n" &
      "  exec \"sleep 30\"\n}\n")
    ctx.startService("getty")
    ctx.startService("daemon")
    let getty = ctx.findService("getty").pid
    let daemon = ctx.findService("daemon").pid
    check getpgid(getty) == getpgrp()
    check getpgid(daemon) == daemon
    check ctx.reaper.isRegistered(getty) and ctx.reaper.isRegistered(daemon)
    ctx.stopService("getty")
    ctx.stopService("daemon")
    check not ctx.reaper.isRegistered(getty)
