import ../../../common/logging
import strutils
import osproc
import fusion/filepermissions
include ../../commonImports
import ../../configParser

proc startMount*(mountName: string) =
  ## Main function for mounts.
  ## mountName can be either:
  ##   - A simple name like "data" (looks for data.kg with type: mount)
  ##   - A qualified name like "example::data" (looks for example.kg, mount "data")

  var unitName = mountName
  var subMountName = "main"

  # Check for qualified name (unit::subunit)
  if "::" in mountName:
    let parts = mountName.split("::", 1)
    unitName = parts[0]
    subMountName = parts[1]

  # Load and parse the unit configuration
  var config: UnitConfig
  try:
    config = parseUnit(configPath, unitName)
  except CatchableError as e:
    warn "Mount "&mountName&" couldn't be started: "&e.msg
    return

  # Validate unit type for non-multi units
  if config.unitType notin {utMount, utMulti}:
    warn "Mount "&mountName&" has an incorrect type: "&($config.unitType)
    return

  # Find the matching mount config
  var mountConfig: MountConfig
  var found = false
  for mnt in config.mounts:
    if mnt.name == subMountName:
      mountConfig = mnt
      found = true
      break

  if not found:
    # For mount type units, there should be a single unnamed mount
    if config.mounts.len == 1:
      mountConfig = config.mounts[0]
      found = true
    else:
      warn "Mount "&mountName&" not found in unit configuration"
      return

  # Validate required fields
  if mountConfig.fromPath == "" or mountConfig.toPath == "" or
      mountConfig.fstype == "":
    warn "Mount "&mountName&" is missing required fields (from, to, fstype)"
    return

  # Create mount point if needed
  if not dirExists(mountConfig.toPath):
    createDir(mountConfig.toPath)
    chmod(mountConfig.toPath, mountConfig.chmod)

  # Build mount command
  var cmd = "mount -t "&mountConfig.fstype&" "&mountConfig.fromPath&" "&mountConfig.toPath

  if mountConfig.extraArgs != "":
    cmd = cmd&" "&mountConfig.extraArgs

  let process = startProcess(command = cmd, options = {poEvalCommand, poUsePath})

  # Handle timeout
  if mountConfig.timeout != "":
    # Parse timeout (e.g., "5s", "1m")
    var timeoutMs = 0
    var timeoutStr = mountConfig.timeout
    if timeoutStr.endsWith("s"):
      timeoutMs = parseInt(timeoutStr[0..^2]) * 1000
    elif timeoutStr.endsWith("m"):
      timeoutMs = parseInt(timeoutStr[0..^2]) * 60 * 1000
    else:
      try:
        timeoutMs = parseInt(timeoutStr) * 1000
      except ValueError:
        timeoutMs = 5000 # Default 5 second timeout

    sleep(timeoutMs)
    if running(process):
      terminate(process)
      discard waitForExit(process)
      close(process)
      warn "Mounting "&mountName&" failed, timeout reached"
      return
  elif waitForExit(process) != 0:
    warn "Mounting "&mountName&" failed, possibly broken configuration"
    return

  close(process)

  # Track mount state
  createDir(serviceHandlerPath&"/mounts/"&mountName)
  writeFile(serviceHandlerPath&"/mounts/"&mountName&"/status", "mounted")
  ok "Mounted "&mountName
