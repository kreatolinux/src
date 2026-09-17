import std/[os, osproc, strutils, tempfiles, unittest, json, monotimes, times]
import ../../krep/modules/isoprocess
when defined(posix):
  import std/posix

# The test binary doubles as a child executable. No shell is involved, even in
# the tests, and real signals are sent only inside this disposable helper.
let cli = commandLineParams()
if cli.len > 0 and cli[0] == "--helper":
  case cli[1]
  of "argv":
    writeFile(cli[2], $(%cli[3..^1]))
  of "fail":
    quit(17)
  of "sleep":
    writeFile(cli[2], $getCurrentProcessId())
    sleep(30_000)
  of "tree":
    let leaf = startProcess(getAppFilename(),
        args = @["--helper", "sleep", cli[2]],
        options = {poParentStreams})
    try:
      sleep(30_000)
    finally:
      leaf.close()
  of "cancel":
    when defined(posix):
      proc trigger(signal: cint) {.noconv, raises: [],
          stackTrace: off, lineTrace: off.} =
        requestCancel()
      var action: Sigaction
      action.sa_handler = trigger
      discard sigemptyset(action.sa_mask)
      discard sigaction(SIGALRM, action)
      var cleaned = false
      var cancelled = false
      withCancellation:
        discard alarm(1)
        try:
          checkedRun(getAppFilename(), @["--helper", "tree", cli[2]])
        except IOError as error:
          cancelled = "cancelled" in error.msg
        finally:
          cleaned = true
          discard alarm(0)
      if not cleaned or not cancelled:
        quit(2)
  of "signal":
    when defined(posix):
      var selectedSignal: cint
      selectedSignal = if cli[2] == "INT": SIGINT else: SIGTERM
      proc trigger(signal: cint) {.noconv, raises: [],
          stackTrace: off, lineTrace: off.} =
        discard posix.kill(getpid(), selectedSignal)
      var action: Sigaction
      action.sa_handler = trigger
      discard sigemptyset(action.sa_mask)
      discard sigaction(SIGALRM, action)
      var cancelled = false
      withCancellation:
        discard alarm(1)
        try:
          checkedRun(getAppFilename(), @["--helper", "sleep", cli[3]])
        except IOError as error:
          cancelled = "cancelled" in error.msg
        finally:
          discard alarm(0)
      if not cancelled:
        quit(3)
  else:
    quit(4)
  quit(0)

suite "checked ISO commands":
  setup:
    let work = createTempDir("krep-isoprocess-", "")
  teardown:
    removeDir(work)

  test "argv is literal, including spaces, quotes, metacharacters and empty args":
    let output = work / "arguments.json"
    let arguments = @["with spaces", "single'quote", "double\"quote", "",
        "$(touch " & work / "injected" & ")", "; exit 99", "*", "a\nb"]
    checkedRun(getAppFilename(), @["--helper", "argv", output] & arguments)
    check parseJson(readFile(output)) == %arguments
    check not fileExists(work / "injected")

  test "nonzero status raises IOError and executes caller cleanup":
    var cleaned = false
    try:
      expect IOError:
        try:
          checkedRun(getAppFilename(), @["--helper", "fail"])
        finally:
          cleaned = true
    finally:
      check cleaned

  test "a missing executable is a catchable error":
    expect OSError:
      checkedRun(work / "does-not-exist", @[])

  test "cancellation checkpoints raise and reset with their scope":
    var cleaned = false
    try:
      withCancellation:
        checkCancellation()
        requestCancel()
        expect IOError:
          checkCancellation()
    finally:
      cleaned = true
    check cleaned
    checkCancellation()

  test "injected cancellation prevents launch and nested scopes retain request":
    withCancellation:
      requestCancel()
      withCancellation:
        expect IOError:
          checkedRun(getAppFilename(), @["--helper", "argv", work / "unexpected"])
      expect IOError:
        checkedRun(getAppFilename(), @["--helper", "argv", work / "unexpected"])
    check not fileExists(work / "unexpected")
    # A new scope resets the old request.
    withCancellation:
      checkedRun(getAppFilename(), @["--helper", "argv", work / "next", "ok"])
    check fileExists(work / "next")

  when defined(posix):
    test "running cancellation stops descendants and runs finally":
      let leafFile = work / "leaf.pid"
      let started = getMonoTime()
      checkedRun(getAppFilename(), @["--helper", "cancel", leafFile])
      check (getMonoTime() - started).inMilliseconds < 5000
      check fileExists(leafFile)
      let leafPid = Pid(parseInt(readFile(leafFile)))
      # On macOS orphaned descendants are promptly reaped by launchd. Linux
      # containers may retain an init-owned zombie; it cannot do further work.
      var alive = true
      for attempt in 0..<40:
        if posix.kill(leafPid, 0) != 0:
          alive = false
          break
        when defined(linux):
          let stat = "/proc/" & $leafPid & "/stat"
          if fileExists(stat) and ") Z " in readFile(stat):
            alive = false
            break
        sleep(25)
      check not alive

    test "SIGINT and SIGTERM cancel only disposable subprocesses":
      for signalName in ["INT", "TERM"]:
        let started = getMonoTime()
        checkedRun(getAppFilename(),
            @["--helper", "signal", signalName, work / signalName])
        check (getMonoTime() - started).inMilliseconds < 5000

    test "scopes restore previous handlers":
      proc original(signal: cint) {.noconv.} = discard
      var action, oldInt, oldTerm: Sigaction
      action.sa_handler = original
      discard sigemptyset(action.sa_mask)
      action.sa_flags = SA_RESTART
      check sigaction(SIGINT, action, oldInt) == 0
      check sigaction(SIGTERM, action, oldTerm) == 0
      try:
        withCancellation:
          withCancellation:
            discard
        # Query using the C API because std/posix requires a non-nil new action.
        proc query(signal: cint, action: pointer,
            oldAction: ptr Sigaction): cint
            {.importc: "sigaction", header: "<signal.h>".}
        var restored: Sigaction
        for signal in [SIGINT, SIGTERM]:
          check query(signal, nil, addr restored) == 0
          check restored.sa_handler == original
          check (restored.sa_flags and SA_RESTART) != 0
      finally:
        discard sigaction(SIGINT, oldInt)
        discard sigaction(SIGTERM, oldTerm)
