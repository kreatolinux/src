# serviceHandler
# JumpStart's service handler
#
# The daemon imports this module. The native backend itself lives in
# native_bridge.nim; this file holds the PID 1 duties (initSystem) and the
# logging initialisation.
import std/os, ../commonImports
import mount_syscalls
import jumpstartcore/[cgroups, reaper]
import globalVariables, native_bridge
import std/[parsecfg, strutils]
import ../../common/logging

export native_bridge, globalVariables

proc initServiceHandlerLogging*(logPath: string;
                                configFile = "/etc/jumpstart/main.conf") =
  ## Initialise logging with the daemon log path of the selected mode (§7.2,
  ## §19.2). The daemon calls this once it has chosen its mode; nothing is
  ## initialised implicitly.
  initLogger("jumpstart", configFile, logPath)

type
  SystemInitOptions* = object
    configFile*: string       ## /etc/jumpstart/main.conf
    cgroupMount*: string      ## /sys/fs/cgroup
    fstabPath*: string        ## /etc/fstab
    defaultHostname*: string

  SystemInitResult* = object
    mountFstab*: bool         ## [System] mount_fstab (default true, §20.2).
    filesystemsReady*: bool   ## True once `mount -a` returned (§20.2).
    cgroupAvailable*: bool    ## cgroup v2 is mounted at cgroupMount.
    cgroupError*: string      ## Why it is not, when it is not.

proc defaultSystemInitOptions*(): SystemInitOptions =
  SystemInitOptions(configFile: "/etc/jumpstart/main.conf",
    cgroupMount: "/sys/fs/cgroup", fstabPath: "/etc/fstab",
    defaultHostname: "klinux")

proc readMountFstab*(configFile: string): bool =
  ## `mount_fstab` in [System] of main.conf. Absent means true (§20.2). Any
  ## other value than true/false is logged and treated as the default.
  result = true
  if not fileExists(configFile): return
  try:
    let value = loadConfig(configFile).getSectionValue("System", "mount_fstab", "")
    case value.strip.toLowerAscii
    of "": discard
    of "true", "yes", "1", "on": result = true
    of "false", "no", "0", "off": result = false
    else:
      warn "Invalid mount_fstab value '" & value & "' in " & configFile &
        "; using the default (true)"
  except CatchableError as e:
    warn "Couldn't read " & configFile & ": " & e.msg

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

when defined(linux):
  const RbDisableCad = cint(0)
  proc linuxReboot(command: cint): cint {.importc: "reboot", header: "<sys/reboot.h>".}

proc initSystem*(reaper: Reaper;
                 options = defaultSystemInitOptions()): SystemInitResult =
  ## Native PID 1 duties (§20.2 step 1): API filesystems, cgroup2, the
  ## optional fstab stage, hostname, and Ctrl-Alt-Del as SIGINT. `mount -a`
  ## runs through the spawn layer and is waited for through `reaper`.
  info "Mounting filesystems..."
  mountWithLog("proc", "/proc", "proc")
  mountWithLog("none", "/dev", "devtmpfs")
  mountWithLog("devpts", "/dev/pts", "devpts")
  mountWithLog("sysfs", "/sys", "sysfs")
  mountWithLog("none", "/run", "tmpfs")

  try:
    ensureCgroupV2(options.cgroupMount)
    result.cgroupAvailable = true
  except CatchableError as e:
    result.cgroupError = e.msg
    warn "cgroup v2 unavailable, serviceHandler runs without cgroups: " & e.msg

  result.mountFstab = readMountFstab(options.configFile)
  if result.mountFstab:
    let ret = mountFs("", "/", "", MS_REMOUNT, "")
    if ret != 0:
      warn "Couldn't remount root as read-write: " & mountErrorStr(ret)
    if fileExists(options.fstabPath):
      try:
        let ctx = newNativeContext("/", "/", reaper)
        let status = ctx.runToCompletion("mount -a", "serviceHandler:mount-a")
        if shellExitCode(status) != 0:
          warn "mount -a failed with exit code " & $shellExitCode(status)
      except CatchableError as e:
        warn "mount -a could not run: " & e.msg
    result.filesystemsReady = true
  else:
    info "mount_fstab is false: leaving / and /etc/fstab to the cores"

  try:
    if fileExists(options.configFile):
      info "Loading configuration..."
      # Note: main.conf is still INI format for system config, not unit definitions
      let conf = loadConfig(options.configFile)
      writeFile("/proc/sys/kernel/hostname", conf.getSectionValue(
              "System", "hostname", options.defaultHostname))
    else:
      writeFile("/proc/sys/kernel/hostname", options.defaultHostname)
  except CatchableError:
    warn "Couldn't load configuration!"

  when defined(linux):
    if linuxReboot(RbDisableCad) != 0:
      warn "Couldn't disable Ctrl-Alt-Del reboot: " & osErrorMsg(osLastError())

# --- bridge construction ----------------------------------------------------

proc configureServiceHandler*(ctx: NativeContext;
                              clientVersion = jumpstartVersion): NativeBridge =
  ## Create a bridge as the daemon's first serviceHandler load does: empties
  ## the runtime directory and reports load errors (a reserved `default.kg`).
  result = newNativeBridge(ctx, resetRuntime = true, clientVersion = clientVersion)
  result.logLoadErrors()
