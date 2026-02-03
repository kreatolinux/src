import std/times
import std/net
import ../../../common/logging
import strutils
include ../../commonImports
import ../globalVariables
import ../../configParser

type TimerArgs = ref object
  timerName: string
  interval: int
  serviceName: string
  onMissed: string
  stopFlag: ptr bool

proc loadPersistedRemaining(timerName: string, interval: int): tuple[
    remaining: int, lastRun: int64] =
  let timerStatePath = serviceHandlerPath&"/timers/"&timerName

  try:
    if fileExists(timerStatePath&"/remaining"):
      let remaining = parseInt(readFile(timerStatePath&"/remaining"))
      var lastRun: int64 = 0
      if fileExists(timerStatePath&"/last_run"):
        lastRun = parseBiggestInt(readFile(timerStatePath&"/last_run"))
      return (remaining: remaining, lastRun: lastRun)
  except CatchableError:
    discard

  return (remaining: interval, lastRun: 0)

proc persistState(timerName: string, remaining: int, lastRun: int64 = 0) =
  let timerStatePath = serviceHandlerPath&"/timers/"&timerName
  discard existsOrCreateDir(timerStatePath)
  try:
    writeFile(timerStatePath&"/remaining", $remaining)
    writeFile(timerStatePath&"/status", "running")
    if lastRun > 0:
      writeFile(timerStatePath&"/last_run", $lastRun)
  except CatchableError:
    stderr.writeLine("jumpstart: Failed to persist state for timer "&timerName)
    stderr.flushFile()

proc triggerService(serviceName: string) =
  let socket = newSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
  try:
    socket.connectUnix(sockPath)
    socket.send("""{ "client": { "name": "Jumpstart Timer", "version": """"&jumpstartVersion&"""" }, "service": { "name": """"&serviceName&"""", "action": "start", "now": "false" }}"""&"\c\l")
    socket.close()
  except CatchableError as e:
    stderr.writeLine("jumpstart: Failed to trigger service "&serviceName&": "&e.msg)
    stderr.flushFile()

proc timerThread(argsPtr: pointer) {.thread.} =
  let args = cast[TimerArgs](argsPtr)
  let currentTime = epochTime().int64

  var (remaining, lastRun) = loadPersistedRemaining(args.timerName, args.interval)

  if lastRun > 0:
    let timeSinceLastRun = currentTime - lastRun
    if timeSinceLastRun >= args.interval:
      if args.onMissed == "run":
        triggerService(args.serviceName)
        lastRun = currentTime
        remaining = args.interval
        persistState(args.timerName, remaining, lastRun)
      else:
        remaining = args.interval - (timeSinceLastRun mod args.interval)
        if remaining < 0:
          remaining = args.interval
    else:
      remaining = remaining - timeSinceLastRun.int
      if remaining < 0:
        remaining = 0

  persistState(args.timerName, remaining, lastRun)

  var counter = 0
  while not args.stopFlag[]:
    if remaining <= 0:
      triggerService(args.serviceName)
      let lastRun = epochTime().int64
      remaining = args.interval
      persistState(args.timerName, remaining, lastRun)

    sleep(1000)
    remaining -= 1
    counter += 1

    if counter >= 60:
      persistState(args.timerName, remaining)
      counter = 0

proc startTimer*(timerName: string) =
  ## Start a timer.
  ## timerName can be either:
  ##   - A simple name like "cleanup" (looks for cleanup.kg with type: timer)
  ##   - A qualified name like "example::cleanup" (looks for example.kg, timer "cleanup")

  var unitName = timerName
  var subTimerName = "main"

  # Check for qualified name (unit::subunit)
  if "::" in timerName:
    let parts = timerName.split("::", 1)
    unitName = parts[0]
    subTimerName = parts[1]

  # Check if already running
  if dirExists(serviceHandlerPath&"/timers/"&timerName):
    warn "Timer "&timerName&" is already running"
    return

  # Load and parse the unit configuration
  var config: UnitConfig
  try:
    config = parseUnit(configPath, unitName)
  except CatchableError as e:
    warn "Timer "&timerName&" couldn't be started: "&e.msg
    return

  # Validate unit type for non-multi units
  if config.unitType notin {utTimer, utMulti}:
    warn "Timer "&timerName&" has an incorrect type: "&($config.unitType)
    return

  # Find the matching timer config
  var timerConfig: TimerConfig
  var found = false
  for tmr in config.timers:
    if tmr.name == subTimerName:
      timerConfig = tmr
      found = true
      break

  if not found:
    # For timer type units, there should be a single unnamed timer
    if config.timers.len == 1:
      timerConfig = config.timers[0]
      found = true
    else:
      warn "Timer "&timerName&" not found in unit configuration"
      return

  # Validate configuration
  if timerConfig.interval <= 0:
    warn "Timer "&timerName&" has invalid interval: "&($(timerConfig.interval))
    return

  if isEmptyOrWhitespace(timerConfig.service):
    warn "Timer "&timerName&" has no Service specified"
    return

  createDir(serviceHandlerPath&"/timers/"&timerName)

  let stopFlag = cast[ptr bool](allocShared0(sizeof(bool)))

  let onMissedStr = case timerConfig.onMissed
    of omRun: "run"
    of omSkip: "skip"

  let args = TimerArgs(
    timerName: timerName,
    interval: timerConfig.interval,
    serviceName: timerConfig.service,
    onMissed: onMissedStr,
    stopFlag: stopFlag
  )

  var thread = cast[ptr Thread[pointer]](allocShared0(sizeof(Thread[pointer])))
  createThread(thread[], timerThread, cast[pointer](args))

  timers.add((timerName: timerName, thread: thread, stopFlag: stopFlag))
  ok "Started timer "&timerName
