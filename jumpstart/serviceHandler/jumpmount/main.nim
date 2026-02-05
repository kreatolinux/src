import ../../../common/logging
import strutils
import osproc
import fusion/filepermissions
include ../../commonImports
import ../../configParser
import ../../mounts

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

  # Perform mount using syscall
  # extraArgs is passed directly as filesystem-specific data string
  let ret = mountFs(mountConfig.fromPath, mountConfig.toPath, mountConfig.fstype,
                    flags = 0, data = mountConfig.extraArgs)

  if ret != 0:
    warn "Mounting " & mountName & " failed: " & mountErrorStr(ret)
    return

  # Track mount state
  createDir(serviceHandlerPath&"/mounts/"&mountName)
  writeFile(serviceHandlerPath&"/mounts/"&mountName&"/status", "mounted")
  ok "Mounted "&mountName
