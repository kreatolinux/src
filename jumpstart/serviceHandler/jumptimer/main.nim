import parsecfg
import std/times
import std/net
import ../../../common/logging
import strutils
include ../../commonImports
import ../globalVariables

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
  var timer: Config

  try:
    if dirExists(serviceHandlerPath&"/timers/"&timerName):
      warn "Timer "&timerName&" is already running"
      return

    createDir(serviceHandlerPath&"/timers/"&timerName)
    timer = loadConfig(timerPath&"/"&timerName)
  except CatchableError:
    warn "Timer "&timerName&" couldn't be started, possibly broken configuration?"
    return

  if timer.getSectionValue("Info", "Type") != "timer":
    warn "Timer "&timerName&" has an incorrect type"
    return

  let interval = parseInt(timer.getSectionValue("Timer", "Interval"))
  let serviceName = timer.getSectionValue("Timer", "Service")
  let onMissed = timer.getSectionValue("Timer", "OnMissed", "skip")

  if interval <= 0:
    warn "Timer "&timerName&" has invalid interval: "&($(interval))
    return

  if isEmptyOrWhitespace(serviceName):
    warn "Timer "&timerName&" has no Service specified"
    return

  let stopFlag = cast[ptr bool](allocShared0(sizeof(bool)))

  let args = TimerArgs(
    timerName: timerName,
    interval: interval,
    serviceName: serviceName,
    onMissed: onMissed,
    stopFlag: stopFlag
  )

  var thread = cast[ptr Thread[pointer]](allocShared0(sizeof(Thread[pointer])))
  createThread(thread[], timerThread, cast[pointer](args))

  timers.add((timerName: timerName, thread: thread, stopFlag: stopFlag))
  ok "Started timer "&timerName
