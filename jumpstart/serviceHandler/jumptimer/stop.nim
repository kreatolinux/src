import ../../../common/logging
import os
import strutils
include ../../commonImports
import ../globalVariables
import std/times

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

  var timerData: TimerData

  for i in 0 ..< timers.len:
    if timers[i].timerName == timerName:
      timerData = timers[i]
      break

  if isEmptyOrWhitespace(timerData.timerName):
    warn "Timer "&timerName&" not found in running timers"
    return

  info "Stopping timer "&timerName

  timerData.stopFlag[] = true
  joinThread(timerData.thread)

  let remaining = loadCurrentRemaining(timerName)
  let timerStatePath = serviceHandlerPath&"/timers/"&timerName

  try:
    writeFile(timerStatePath&"/remaining", $remaining)
    writeFile(timerStatePath&"/status", "stopped")
  except CatchableError:
    warn "Failed to persist state for stopped timer "&timerName

  deallocShared(timerData.stopFlag)

  var newTimers: seq[TimerData]
  for t in timers:
    if t.timerName != timerName:
      newTimers = newTimers & t
  timers = newTimers

  ok "Stopped timer "&timerName
