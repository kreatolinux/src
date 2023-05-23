# serviceHandler
# JumpStart's service handler
include ../commonImports
import enable, disable, start, stop
import os, osproc
import parsecfg
import ../logging
import jumpmount/main
import jumpmount/umount

proc execLoggedCmd(cmd: string, err: string) =
    ## execShellCmd with simple if statement
    discard existsOrCreateDir(err)
    if err != "/proc" and execCmdEx("mountpoint "&err).exitCode == 0:
        info_msg err&" already mounted, skipping"
        return

    if execShellCmd(cmd) != 0:
        error "Couldn't mount "&err

proc initSystem() =
    ## Initialize system such as mounting /proc, /dev, putting the hostname, etc.
    info_msg "Mounting filesystems..."
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
            info_msg "Loading configuration..."
            let conf = loadConfig("/etc/jumpstart/main.conf")
            writeFile("/proc/sys/kernel/hostname", conf.getSectionValue("System", "hostname", defaultHostname)
        else:
            writeFile("/proc/sys/kernel/hostname", defaultHostname)
    except CatchableError:
        warn "Couldn't load configuration!"

proc serviceHandlerInit() =
    ## Initialize serviceHandler.
    discard existsOrCreateDir(servicePath)
    removeDir("/run/serviceHandler")

    for i in walkFiles(mountPath&"/enabled/*.mount"):
        startMount(extractFilename(i))

    for i in walkFiles(servicePath&"/enabled/*.service"):
        startService(extractFilename(i))

