# serviceHandler
# JumpStart's service handler
include ../commonImports
import ../types
import ../configParser
import ../dephandler
import enable, disable, start, stop
import osproc
import parsecfg
import strutils
import ../../common/logging
import jumpmount/main
import jumpmount/umount
import jumptimer/main
import jumptimer/stop

# Initialize logging for jumpstart serviceHandler
initLogger("jumpstart", "/etc/jumpstart/main.conf", "/var/log/jumpstart.log")

proc execLoggedCmd(cmd: string, err: string) =
  ## execShellCmd with simple if statement
  discard existsOrCreateDir(err)
  if err != "/proc" and execCmdEx("mountpoint "&err).exitCode == 0:
    info err&" already mounted, skipping"
    return

  if execShellCmd(cmd) != 0:
    fatal "Couldn't mount "&err

proc initSystem() =
  ## Initialize system such as mounting /proc, /dev, putting the hostname, etc.
  info "Mounting filesystems..."
  if fileExists("/etc/fstab"):
    execLoggedCmd("mount -a", "fstab")
  execLoggedCmd("mount -t proc proc /proc", "/proc")
  execLoggedCmd("mount -t devtmpfs none /dev", "/dev")
  execLoggedCmd("mount -t devpts devpts /dev/pts", "/dev/pts")
  execLoggedCmd("mount -t sysfs sysfs /sys", "/sys")
  execLoggedCmd("mount -t tmpfs none /run", "/run")
  execLoggedCmd("mount -o remount,rw /", "rootfs")

  let defaultHostname = "klinux"

  try:
    if fileExists("/etc/jumpstart/main.conf"):
      info "Loading configuration..."
      # Note: main.conf is still INI format for system config, not unit definitions
      let conf = loadConfig("/etc/jumpstart/main.conf")
      writeFile("/proc/sys/kernel/hostname", conf.getSectionValue(
              "System", "hostname", defaultHostname))
    else:
      writeFile("/proc/sys/kernel/hostname", defaultHostname)
  except CatchableError:
    warn "Couldn't load configuration!"

proc startUnit(config: UnitConfig, unitName: string) =
  ## Start a unit based on its type and configuration
  case config.unitType
  of utSimple, utOneshot:
    # Simple service unit
    startService(unitName)
  of utTimer:
    # Timer unit
    startTimer(unitName)
  of utMount:
    # Mount unit
    startMount(unitName)
  of utMulti:
    # Multi-unit: start all sub-units in order
    # Start mounts first
    for mnt in config.mounts:
      startMount(unitName & "::" & mnt.name)
    # Then services
    for svc in config.services:
      startService(unitName & "::" & svc.name)
    # Then timers
    for tmr in config.timers:
      startTimer(unitName & "::" & tmr.name)

proc serviceHandlerInit() =
  ## Initialize serviceHandler.
  ## Uses dependency resolution to start units in correct order
  discard existsOrCreateDir(configPath)
  discard existsOrCreateDir(configPath & "/enabled")
  removeDir(serviceHandlerPath)

  # Collect all enabled units
  var enabledUnits: seq[string] = @[]
  let enabledDir = configPath & "/enabled"
  if dirExists(enabledDir):
    for kind, path in walkDir(enabledDir):
      if kind in {pcFile, pcLinkToFile}:
        let unitName = extractFilename(path).replace(".kg", "")
        enabledUnits.add(unitName)

  if enabledUnits.len == 0:
    info "No enabled units found"
    return

  # Resolve dependency order
  var startOrder: seq[string]
  try:
    startOrder = getStartOrder(enabledUnits)
    info "Start order: " & startOrder.join(", ")
  except DependencyError as e:
    fatal "Dependency resolution failed: " & e.msg
    return

  # Start units in resolved order
  for unitName in startOrder:
    # Only start if it's in the enabled list (dependencies might be pulled in but not enabled)
    if unitName notin enabledUnits:
      continue

    try:
      let config = parseUnit(configPath, unitName)

      # Validate hard dependencies are running
      let (valid, missing) = validateDependencies(unitName)
      if not valid:
        warn "Unit " & unitName & " has missing dependencies: " & missing.join(", ")
        continue

      startUnit(config, unitName)
    except CatchableError as e:
      warn "Failed to start enabled unit " & unitName & ": " & e.msg
