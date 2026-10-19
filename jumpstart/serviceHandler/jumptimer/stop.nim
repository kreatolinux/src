## Native timer units: disarming.
import std/[os, strutils]
import ../../../common/logging
import ../globalVariables

proc loadCurrentRemaining(stateDir: string): int =
  try:
    if fileExists(stateDir / "remaining"):
      return parseInt(readFile(stateDir / "remaining"))
  except CatchableError:
    discard
  return 0

proc stopTimer*(ctx: NativeContext; timerName: string) =
  ## Disarm a timer. Does not stop a unit it already triggered. Disarming a
  ## timer that is not armed is a success.
  let timerIndex = ctx.findTimerIndex(timerName)
  if timerIndex == -1:
    info "Timer " & timerName & " is already not running"
    return

  info "Stopping timer " & timerName
  let record = ctx.timers[timerIndex]
  record.stopFlag[] = true
  joinThread(record.thread[])

  let stateDir = ctx.timerStateDir(timerName)
  let remaining = loadCurrentRemaining(stateDir)
  try:
    writeFile(stateDir / "remaining", $remaining)
    writeFile(stateDir / "status", "stopped")
  except CatchableError:
    warn "Failed to persist state for stopped timer " & timerName

  deallocShared(record.stopFlag)
  deallocShared(record.thread)
  ctx.timers.del(timerIndex)
  ok "Stopped timer " & timerName
