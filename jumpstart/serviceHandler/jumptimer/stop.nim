import ../../../common/logging
import strutils
include ../../commonImports
import ../globalVariables

proc loadCurrentRemaining(timerName: string): int =
  let timerStatePath = serviceHandlerPath&"/timers/"&timerName
  try:
    if fileExists(timerStatePath&"/remaining"):
      return parseInt(readFile(timerStatePath&"/remaining"))
  except CatchableError:
    discard
  return 0

proc stopTimer*(timerName: string) =
  if not dirExists(serviceHandlerPath&"/timers/"&timerName):
    info "Timer "&timerName&" is already not running"
    return

  var timerIndex = -1

  for i in 0 ..< timers.len:
    if timers[i].timerName == timerName:
      timerIndex = i
      break

  if timerIndex == -1:
    warn "Timer "&timerName&" not found in running timers"
    return

  info "Stopping timer "&timerName

  timers[timerIndex].stopFlag[] = true
  joinThread(timers[timerIndex].thread[])

  let remaining = loadCurrentRemaining(timerName)
  let timerStatePath = serviceHandlerPath&"/timers/"&timerName

  try:
    writeFile(timerStatePath&"/remaining", $remaining)
    writeFile(timerStatePath&"/status", "stopped")
  except CatchableError:
    warn "Failed to persist state for stopped timer "&timerName

  deallocShared(timers[timerIndex].stopFlag)
  deallocShared(timers[timerIndex].thread)
  timers.del(timerIndex)

  ok "Stopped timer "&timerName
