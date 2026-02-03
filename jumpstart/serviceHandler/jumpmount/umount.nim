import osproc
import strutils
import ../../../common/logging
include ../../commonImports
import ../../configParser

proc stopMount*(mountName: string) =
  ## Stop a mount unit
  ## mountName can be either:
  ##   - A simple name like "data" (looks for data.kg with type: mount)
  ##   - A qualified name like "example::data" (looks for example.kg, mount "data")

  if not dirExists(serviceHandlerPath&"/mounts/"&mountName):
    warn "Mount "&mountName&" is not running, no need to try stopping it"
    return

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
    warn "Mount "&mountName&" couldn't be loaded: "&e.msg
    return

  # Find the matching mount config
  var mountConfig: MountConfig
  var found = false
  for mnt in config.mounts:
    if mnt.name == subMountName:
      mountConfig = mnt
      found = true
      break

  if not found and config.mounts.len == 1:
    mountConfig = config.mounts[0]
    found = true

  if not found:
    warn "Mount "&mountName&" not found in unit configuration"
    return

  var cmd = "umount"

  if mountConfig.lazyUnmount:
    cmd = cmd&" -l"

  cmd = cmd&" "&mountConfig.toPath

  let process = startProcess(command = cmd, options = {poEvalCommand, poUsePath})
  discard waitForExit(process)
  close(process)

  removeDir(serviceHandlerPath&"/mounts/"&mountName)
  ok "Unmounted "&mountName
