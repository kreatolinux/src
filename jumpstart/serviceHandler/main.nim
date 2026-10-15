# serviceHandler
# JumpStart's service handler
include ../commonImports
import ../types
import ../configParser
import ../unitname
import ../unitdispatch
import ../dephandler
import ../mounts
import ../exec
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

proc mountWithLog(source, target, fstype: string, flags: culong = 0,
    data: string = "") =
  ## Mount a filesystem using syscall with logging.
  discard existsOrCreateDir(target)

  if isMounted(target):
    info target & " already mounted, skipping"
    return

  let ret = mountFs(source, target, fstype, flags, data)
  if ret != 0:
    fatal "Couldn't mount " & target & ": " & mountErrorStr(ret)

proc initSystem() =
  ## Initialize system such as mounting /proc, /dev, putting the hostname, etc.
  ## Uses direct mount syscalls instead of shell commands.
  info "Mounting filesystems..."

  # Mount essential filesystems using syscalls
  mountWithLog("proc", "/proc", "proc")
  mountWithLog("none", "/dev", "devtmpfs")
  mountWithLog("devpts", "/dev/pts", "devpts")
  mountWithLog("sysfs", "/sys", "sysfs")
  mountWithLog("none", "/run", "tmpfs")

  # Remount root as read-write
  let ret = mountFs("", "/", "", MS_REMOUNT, "")
  if ret != 0:
    warn "Couldn't remount root as read-write: " & mountErrorStr(ret)

  # Mount fstab entries using mount -a
  if fileExists("/etc/fstab"):
    let exitCode = execDirectWait("/bin/mount -a", {poUsePath})
    if exitCode != 0:
      warn "mount -a failed with exit code " & $exitCode

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

proc startRequestedUnit*(requestedName: string) =
  let normalized = normalizeUnitName(requestedName)
  try:
    let config = parseUnit(configPath, unitBaseName(normalized))
    if "::" notin normalized:
      startUnit(config, normalized)
    else:
      case requestedUnitKind(config, normalized)
      of ukMount: startMount(normalized)
      of ukTimer: startTimer(normalized)
      of ukService: startService(normalized)
  except CatchableError as e:
    warn "Couldn't start unit " & normalized & ": " & e.msg

proc stopUnit(config: UnitConfig, unitName: string) =
  case config.unitType
  of utSimple, utOneshot:
    stopService(unitName)
  of utTimer:
    stopTimer(unitName)
  of utMount:
    stopMount(unitName)
  of utMulti:
    # Reverse startup order when stopping a complete multi-unit.
    for i in countdown(config.timers.high, 0):
      stopTimer(unitName & "::" & config.timers[i].name)
    for i in countdown(config.services.high, 0):
      stopService(unitName & "::" & config.services[i].name)
    for i in countdown(config.mounts.high, 0):
      stopMount(unitName & "::" & config.mounts[i].name)

proc stopRequestedUnit*(requestedName: string) =
  let normalized = normalizeUnitName(requestedName)
  try:
    let config = parseUnit(configPath, unitBaseName(normalized))
    if "::" notin normalized:
      stopUnit(config, normalized)
    else:
      case requestedUnitKind(config, normalized)
      of ukMount: stopMount(normalized)
      of ukTimer: stopTimer(normalized)
      of ukService: stopService(normalized)
  except CatchableError as e:
    warn "Couldn't stop unit " & normalized & ": " & e.msg

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
