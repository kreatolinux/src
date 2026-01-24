# serviceHandler
# JumpStart's service handler
include ../commonImports
import ../types
import enable, disable, start, stop
import osproc
import os
import parsecfg
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
      let conf = loadConfig("/etc/jumpstart/main.conf")
      writeFile("/proc/sys/kernel/hostname", conf.getSectionValue(
              "System", "hostname", defaultHostname))
    else:
      writeFile("/proc/sys/kernel/hostname", defaultHostname)
  except CatchableError:
    warn "Couldn't load configuration!"

proc serviceHandlerInit() =
  ## Initialize serviceHandler.
  discard existsOrCreateDir(servicePath)
  removeDir(serviceHandlerPath)

  for i in walkFiles(mountPath&"/enabled/*.mount"):
    startMount(extractFilename(i))

  for i in walkFiles(servicePath&"/enabled/*.service"):
    startService(extractFilename(i))

  for i in walkFiles(timerPath&"/enabled/*.timer"):
    startTimer(extractFilename(i))

