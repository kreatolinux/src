## Native timer units: arming, and timer status.
import std/[json, net, os, strutils, times]
import ../../../common/logging
import ../../configParser
import jumpstartcore/errors
import ../globalVariables
import ../start
import ../status_text
import ../status

const TimerSliceMs = 20

proc loadPersistedRemaining(stateDir: string, interval: int): tuple[
    remaining: int, lastRun: int64] =
  try:
    if fileExists(stateDir / "remaining"):
      let remaining = parseInt(readFile(stateDir / "remaining"))
      var lastRun: int64 = 0
      if fileExists(stateDir / "last_run"):
        lastRun = parseBiggestInt(readFile(stateDir / "last_run"))
      return (remaining: remaining, lastRun: lastRun)
  except CatchableError:
    discard
  return (remaining: interval, lastRun: 0'i64)

proc persistState(stateDir: string, remaining: int, lastRun: int64 = 0) =
  discard existsOrCreateDir(stateDir)
  try:
    writeFile(stateDir / "remaining", $remaining)
    writeFile(stateDir / "status", "running")
    if lastRun > 0:
      writeFile(stateDir / "last_run", $lastRun)
  except CatchableError:
    stderr.writeLine("jumpstart: Failed to persist state for timer " & stateDir)
    stderr.flushFile()

proc triggerService(args: TimerArgs) =
  ## Ask the daemon to start the timer's service, so the start runs on the
  ## daemon thread like any other request. The reference is qualified because
  ## a timer triggers a unit of its own core.
  let socket = newSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
  try:
    socket.connectUnix(args.socketPath)
    let message = %* {"client": {"name": "Jumpstart Timer",
                                 "version": args.clientVersion},
                      "service": {"name": "serviceHandler/" & args.serviceName,
                                  "action": "start"}}
    socket.send($message & "\c\l")
    # Read the response so the daemon never writes to a closed socket, but
    # give up early when the timer is being stopped (the daemon thread may be
    # the one waiting for this thread).
    for _ in 1 .. 600:
      try:
        discard socket.recvLine(timeout = 100)
        break
      except TimeoutError:
        if args.stopFlag[]: break
  except CatchableError as e:
    stderr.writeLine("jumpstart: Failed to trigger service " & args.serviceName &
      ": " & e.msg)
    stderr.flushFile()
  finally:
    socket.close()

proc timerThread(args: TimerArgs) {.thread.} =
  let currentTime = epochTime().int64
  var (remaining, lastRun) = loadPersistedRemaining(args.stateDir, args.interval)

  if lastRun > 0:
    let timeSinceLastRun = currentTime - lastRun
    if timeSinceLastRun >= args.interval:
      if args.onMissed == "run":
        triggerService(args)
        lastRun = currentTime
        remaining = args.interval
        persistState(args.stateDir, remaining, lastRun)
      else:
        remaining = args.interval - int(timeSinceLastRun mod args.interval)
        if remaining < 0:
          remaining = args.interval
    else:
      remaining = remaining - timeSinceLastRun.int
      if remaining < 0:
        remaining = 0

  persistState(args.stateDir, remaining, lastRun)

  var counter = 0
  while not args.stopFlag[]:
    if remaining <= 0:
      triggerService(args)
      let lastRun = epochTime().int64
      remaining = args.interval
      persistState(args.stateDir, remaining, lastRun)

    # One second in short slices, so stopping the timer is noticed within
    # TimerSliceMs instead of waiting out the second (stopTimer joins this
    # thread on the daemon thread).
    var slices = 0
    while slices < 1000 div TimerSliceMs and not args.stopFlag[]:
      sleep(TimerSliceMs)
      inc slices
    if args.stopFlag[]: break
    remaining -= 1
    counter += 1

    if counter >= 60:
      persistState(args.stateDir, remaining)
      counter = 0

proc findTimerConfig*(ctx: NativeContext; timerName: string): TimerConfig =
  ## `cleanup` (cleanup.kg with type timer) or `example::cleanup`.
  let (definition, sub) = splitUnitName(timerName)
  var config: UnitConfig
  try:
    config = parseUnit(ctx.configRoot, definition)
  except CatchableError as e:
    nativeFail(ecNotFound, "timer " & timerName & " couldn't be loaded: " & e.msg)
  if config.unitType notin {utTimer, utMulti}:
    nativeFail(ecNotFound, "timer " & timerName & " has an incorrect type: " &
      $config.unitType)
  for tmr in config.timers:
    if tmr.name == sub: return tmr
  if "::" notin timerName and config.timers.len == 1:
    return config.timers[0]
  nativeFail(ecNotFound, "timer " & timerName & " not found in unit configuration")

proc startTimer*(ctx: NativeContext; timerName: string;
                 clientVersion = "jumpstart") =
  ## Arm a timer. Arming an armed timer is a success.
  if ctx.findTimerIndex(timerName) >= 0:
    info "Timer " & timerName & " is already running"
    return
  let timerConfig = ctx.findTimerConfig(timerName)
  if timerConfig.interval <= 0:
    nativeFail(ecBackend, "timer " & timerName & " has invalid interval: " &
      $timerConfig.interval)
  if isEmptyOrWhitespace(timerConfig.service):
    nativeFail(ecBackend, "timer " & timerName & " has no service specified")

  let stateDir = ctx.timerStateDir(timerName)
  try: createDir(stateDir)
  except CatchableError as e:
    nativeFail(ecIo, "cannot create runtime state of " & timerName & ": " & e.msg)
  let stopFlag = cast[ptr bool](allocShared0(sizeof(bool)))
  let onMissedStr = case timerConfig.onMissed
    of omRun: "run"
    of omSkip: "skip"
  let args = TimerArgs(timerName: timerName, interval: timerConfig.interval,
    serviceName: timerConfig.service, onMissed: onMissedStr, stateDir: stateDir,
    socketPath: ctx.socketPath, clientVersion: clientVersion, stopFlag: stopFlag)
  # The status file exists before start returns, so status is immediately
  # `running`.
  persistState(stateDir, loadPersistedRemaining(stateDir, timerConfig.interval).remaining)
  let thread = cast[ptr Thread[TimerArgs]](allocShared0(sizeof(Thread[TimerArgs])))
  createThread(thread[], timerThread, args)
  ctx.timers.add(TimerRecord(timerName: timerName, thread: thread, stopFlag: stopFlag))
  ok "Started timer " & timerName

proc rfc3339(epoch: int64): string =
  fromUnix(epoch).utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

proc timerStatus*(ctx: NativeContext; timerName: string): JsonNode =
  ## `timer.status` without `enablement`.
  let stateDir = ctx.timerStateDir(timerName)
  var text = ""
  let present = readStatusFile(stateDir / "status", text)
  let mapping = mapNativeStatus(text, present, false)
  result = %* {"state": mapping.state,
               "detail": (if present: text else: MissingStatusText)}
  try:
    if fileExists(stateDir / "last_run"):
      result["last_run"] = %rfc3339(parseBiggestInt(readFile(stateDir / "last_run").strip))
    if mapping.state == "active" and fileExists(stateDir / "remaining"):
      let remaining = parseBiggestInt(readFile(stateDir / "remaining").strip)
      result["next_run"] = %rfc3339(epochTime().int64 + max(remaining, 0))
  except CatchableError: discard
