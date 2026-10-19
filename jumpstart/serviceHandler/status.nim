## Exit handling and status reporting for native services.
##
## The central reaper delivers each main-process exit to `onServiceExit`,
## which writes the historical status file and runs `execPost` (itself through
## the reaper). Nothing here waits for a process.
import std/[json, os, strutils]
import ../../common/logging
import globalVariables, status_text

proc writeStatus(ctx: NativeContext; name, text: string) =
  let dir = ctx.serviceStateDir(name)
  try:
    createDir(dir)
    writeFile(dir / "status", text)
  except CatchableError as e:
    warn "Could not write status of " & name & ": " & e.msg

proc onServiceExit*(ctx: NativeContext; record: ServiceRecord;
                    status: ChildStatus) =
  ## Reaper callback for a service's main process.
  record.running = false
  record.exitStatus = status
  record.exitCode = shellExitCode(status)
  record.exitSeq = ctx.nextSequence()
  ctx.recordServiceExit(record.name, record.requestedStop)
  if record.exitCode == 0:
    if record.postCommand.len > 0:
      record.postRunning = true
      try:
        discard ctx.spawnUnitProcess(record.postCommand, record.terminal,
          record.cgroup, "serviceHandler:" & record.name & ":post",
          proc(s: ChildStatus) =
            record.postRunning = false
            ctx.writeStatus(record.name, "stopped"))
        return
      except CatchableError as e:
        record.postRunning = false
        warn "execPost of " & record.name & " could not start: " & e.msg
    ctx.writeStatus(record.name, "stopped")
  else:
    ctx.writeStatus(record.name, ExitCodePrefix & $record.exitCode)

proc readStatusFile*(path: string; text: var string): bool =
  if not fileExists(path): return false
  try:
    text = readFile(path)
    true
  except CatchableError:
    false

proc cgroupPids*(ctx: NativeContext; cgroup: string): seq[int] =
  if cgroup.len == 0 or ctx.cgroups.isNone: return
  try:
    for line in ctx.cgroupSystem.readFile(cgroup / "cgroup.procs").splitLines:
      let item = line.strip
      if item.len > 0: result.add(parseInt(item))
  except CatchableError: discard

proc serviceStatus*(ctx: NativeContext; name: string): JsonNode =
  ## `service.status` without `enablement` (added by the bridge).
  var text = ""
  let present = readStatusFile(ctx.serviceStateDir(name) / "status", text)
  let mapping = mapNativeStatus(text, present, ctx.lastServiceExitWasRequested(name))
  result = %* {"state": mapping.state,
               "detail": (if present: text else: MissingStatusText)}
  if mapping.hasExitCode: result["exit_code"] = %mapping.exitCode
  let record = ctx.findService(name)
  if not record.isNil and record.running and mapping.state == "active":
    result["main_pid"] = %int(record.pid)
    let pids = ctx.cgroupPids(record.cgroup)
    if pids.len > 0: result["pids"] = %pids
