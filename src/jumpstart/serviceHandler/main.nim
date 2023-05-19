# serviceHandler
# JumpStart's service handler
include ../commonImports
import enable, disable, start, stop
import os
import ../logging
import jumpmount/main
import jumpmount/umount

proc execLoggedCmd(cmd: string, err: string) =
    ## execShellCmd with simple if statement
    if execShellCmd(cmd) != 0:
        error err

proc initDirectories() =
    ## Initialize directories such as /proc, /dev, etc.
    info_msg "Mounting filesystems..."
    if fileExists("/etc/fstab"):
        execLoggedCmd("mount -a", "Couldn't mount fstab entries")
    execLoggedCmd("mount -o remount,rw /", "Couldn't mount rootfs")
    execLoggedCmd("mount -t proc none /proc", "Couldn't mount /proc")
    execLoggedCmd("mount -t devtmpfs none /dev", "Couldn't mount /dev")
    execLoggedCmd("mount -t devpts devpts /dev/pts", "Couldn't mount /dev/pts")
    execLoggedCmd("mount -t sysfs sysfs /sys", "Couldn't mount /sys")
    execLoggedCmd("mount -t tmpfs none /run", "Couldn't mount /run")

proc serviceHandlerInit() =
    ## Initialize serviceHandler.
    discard existsOrCreateDir(servicePath)
    removeDir("/run/serviceHandler")

    for i in walkFiles(mountPath&"/enabled/*.mount"):
        startMount(extractFilename(i))

    for i in walkFiles(servicePath&"/enabled/*.service"):
        startService(extractFilename(i))

