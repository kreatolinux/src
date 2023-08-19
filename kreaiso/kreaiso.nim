#
# Kreato Linux's ISO builder.
# Currently only supports systemd configurations.
#
import os
import osproc
import cligen
import parsecfg
import sequtils
import ../common/logging
import ../common/version
import ../kpkg/commands/buildcmd
import ../kpkg/commands/updatecmd

const tmpDir = "/tmp/kreaiso-tmp"

proc pkgExists(packageName: string) =
    # Checks if a package exists or not, and installs it if it doesn't.
    if not dirExists("/var/cache/kpkg/installed/"&packageName):
        info_msg(packageName&" couldn't be found, installing")
        discard build(yes = true, root = "/", packages = toSeq([packageName]),
                useCacheIfAvailable = true)

proc attemptExec(command: string, errorString: string) =
    # Attempts to run a command, bails if it fails.
    debug("Running "&command)
    let step = execCmdEx(command)

    if step.exitCode != 0:
        debug(step.output)
        error(errorString)

proc kreaiso(rootfs: string, output: string) =
    info_msg("kreaiso, built with commit "&commitVer)

    if dirExists(tmpDir):
        info_msg("tmpDir exists, removing")
        removeDir(tmpDir)

    info_msg("Initializing directories")

    createDir(tmpDir)
    createDir(tmpDir&"/mnt")
    createDir(tmpDir&"/squashfs-root")
    createDir(tmpDir&"/squashfs-root/LiveOS")
    createDir(tmpDir&"/out")
    createDir(tmpDir&"/out/LiveOS")
    createDir(tmpDir&"/temp-rootfs")

    attemptExec("tar --same-owner -xvf "&rootfs&" -C "&tmpDir&"/temp-rootfs", "An error occured while trying to extract the tarball")

    if not fileExists(tmpDir&"/temp-rootfs/etc/kreato-release"):
        error("kreato-release doesn't exist on the rootfs")

    var krelease: Config

    try:
        krelease = loadConfig(tmpDir&"/temp-rootfs/etc/kreato-release")

        if krelease.getSectionValue("Core", "init") != "systemd":
            error("kreaiso currently only support systemd-based systems")
    except Exception:
        error("Invalid kreato-release, possibly broken rootfs")

    discard update()

    pkgExists("squashfs-tools")
    pkgExists("util-linux")
    pkgExists("util-linux")
    pkgExists("gawk")
    pkgExists("e2fsprogs")
    pkgExists("dracut")
    pkgExists("linux")
    pkgExists("grub")
    pkgExists("grub-efi")
    pkgExists("systemd")


    attemptExec("dd if=/dev/zero of="&tmpDir&"/squashfs-root/LiveOS/rootfs.img bs=1024 count=$(du -s "&tmpDir&"/temp-rootfs | awk '{ print $1 }')", "Creating the rootfs image failed")
    attemptExec("losetup /dev/loop0 "&tmpDir&"/squashfs-root/LiveOS/rootfs.img", "Trying to mount newly-created image failed")
    attemptExec("mkfs.ext4 /dev/loop0", "Trying to format newly-created image as ext4 failed")
    attemptExec("mount /dev/loop0 "&tmpDir&"/mnt", "Trying to mount image failed")
    attemptExec("cp -a "&tmpDir&"/temp-rootfs/. "&tmpDir&"/mnt", "Trying to copy rootfs contents to image failed")
    attemptExec("umount /mnt", "Trying to unmount failed")
    attemptExec("losetup -d /dev/loop0", "Trying to detach loop0 failed")

    attemptExec("mksquashfs "&tmpDir&"/squashfs-root "&tmpDir&"/out/LiveOS/squashfs.img", "Creating squashfs image failed")
    attemptExec("dracut --tmpdir /tmp -N --kver -m dmsquash-live 6.4.9", "Creating initramfs failed")
    attemptExec("cp -r /boot/ "&tmpDir&"/out", "Copying /boot to out directory failed")
    createDir(tmpDir&"/out/grub")
    copyFile("grub.cfg", tmpDir&"/out/grub/grub.cfg")
    info_msg("Generating final image...")
    attemptExec("grub-mkrescue -o kreatolinux-"&krelease.getSectionValue(
            "General", "dateBuilt")&"-"&krelease.getSectionValue("General",
            "klinuxVersion")&".iso /out/", "Generating final image failed")


dispatch kreaiso
