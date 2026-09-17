import std/[os, strutils, tempfiles, unittest]
import ../../krep/modules/bootconfig

proc executable(path: string) =
  createDir(path.parentDir)
  writeFile(path, "#!/bin/sh\n")
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})

suite "init-independent live ISO boot":
  setup:
    let work = createTempDir("kreaiso-test-", "")
    let rootfs = work / "rootfs"
    let dataDir = work / "data"
    createDir(rootfs)
    createDir(dataDir)
  teardown:
    removeDir(work)

  test "absolute init symlinks resolve inside the rootfs":
    executable(rootfs / "bin/jumpstart")
    createDir(rootfs / "sbin")
    createSymlink("/bin/jumpstart", rootfs / "sbin/init")
    validateRootfsInit(rootfs, "/sbin/init")
    check resolveRootfsPath(rootfs, "/sbin/init") == rootfs / "bin/jumpstart"

  test "usr-merged sbin and relative symlinks":
    executable(rootfs / "usr/bin/openrc-init")
    createDir(rootfs / "usr/sbin")
    createSymlink("usr/sbin", rootfs / "sbin")
    createSymlink("../bin/openrc-init", rootfs / "usr/sbin/init")
    validateRootfsInit(rootfs, "/sbin/init")
    check resolveRootfsPath(rootfs, "/sbin/init") == rootfs / "usr/bin/openrc-init"

  test "missing init does not fall back to host files":
    createDir(rootfs / "sbin")
    createSymlink("/bin/sh", rootfs / "sbin/init")
    expect ValueError: validateRootfsInit(rootfs, "/sbin/init")

  test "symlink loops are rejected":
    createDir(rootfs / "sbin")
    createSymlink("/sbin/init", rootfs / "sbin/init")
    expect ValueError: validateRootfsInit(rootfs, "/sbin/init")

  test "non-executable init is rejected":
    createDir(rootfs / "sbin")
    writeFile(rootfs / "sbin/init", "not executable")
    expect ValueError: validateRootfsInit(rootfs, "/sbin/init")

  test "custom init path needs no known init name":
    executable(rootfs / "opt/custom/init")
    prepareLiveRootfs(rootfs, dataDir, "my-init", "/opt/custom/init")
    prepareLiveRootfs(rootfs, dataDir, "", "/opt/custom/init")

  test "invalid command-line init paths are rejected":
    for path in ["sbin/init", "/", "/sbin/init quiet", "/sbin/init;reboot",
                 "/sbin/init\n", "/../bin/init", "/init'", "/init$foo"]:
      expect ValueError: validateInitPath(path)

  test "common overlay is shared but systemd customizations are isolated":
    executable(rootfs / "sbin/init")
    createDir(dataDir / "overlay/etc")
    writeFile(dataDir / "overlay/etc/motd", "live")
    createDir(dataDir / "overlays/systemd/etc/systemd")
    writeFile(dataDir / "overlays/systemd/etc/systemd/live.conf", "systemd only")
    createDir(rootfs / "usr/lib/systemd/system")
    let firstboot = rootfs / "usr/lib/systemd/system/systemd-firstboot.service"
    writeFile(firstboot, "unit")
    prepareLiveRootfs(rootfs, dataDir, "jumpstart", "/sbin/init")
    check readFile(rootfs / "etc/motd") == "live"
    check not dirExists(rootfs / "etc/systemd")
    check fileExists(firstboot)
    prepareLiveRootfs(rootfs, dataDir, "systemd", "/sbin/init")
    check fileExists(rootfs / "etc/systemd/live.conf")
    check readFile(firstboot) == "unit"
    # Repeating preparation must preserve the existing login setup.
    prepareLiveRootfs(rootfs, dataDir, "systemd", "/sbin/init")
    check readFile(firstboot) == "unit"

  test "bundled defaults preserve root credentials and login configuration":
    executable(rootfs / "sbin/init")
    createDir(rootfs / "etc/systemd/system/getty@.service.d")
    createDir(rootfs / "usr/lib/systemd/system")
    let shadow = rootfs / "etc/shadow"
    let passwd = rootfs / "etc/passwd"
    let getty = rootfs / "etc/systemd/system/getty@.service.d/site.conf"
    let firstboot = rootfs / "usr/lib/systemd/system/systemd-firstboot.service"
    writeFile(shadow, "root:!locked:20000:0:99999:7:::\n")
    writeFile(passwd, "root:x:0:0:root:/root:/bin/sh\n")
    writeFile(getty, "[Service]\nEnvironment=SITE_LOGIN=1\n")
    writeFile(firstboot, "[Unit]\nDescription=First boot\n")
    setFilePermissions(shadow, {fpUserRead, fpUserWrite})
    let bundledData = currentSourcePath().parentDir / "../../krep/data/iso"
    for initSystem in ["systemd", "jumpstart", "custom", ""]:
      prepareLiveRootfs(rootfs, bundledData, initSystem, "/sbin/init")
      check readFile(shadow) == "root:!locked:20000:0:99999:7:::\n"
      check getFilePermissions(shadow) == {fpUserRead, fpUserWrite}
      check readFile(passwd) == "root:x:0:0:root:/root:/bin/sh\n"
      check readFile(getty) == "[Service]\nEnvironment=SITE_LOGIN=1\n"
      check readFile(firstboot) == "[Unit]\nDescription=First boot\n"
      check not fileExists(rootfs / "etc/systemd/system/getty@.service.d/skip-prompt.conf")

  test "overlay directories resolve absolute destination links inside rootfs":
    executable(rootfs / "sbin/init")
    createDir(rootfs / "usr/etc")
    createSymlink("/usr/etc", rootfs / "etc")
    createDir(dataDir / "overlay/etc")
    writeFile(dataDir / "overlay/etc/live.conf", "staged only")
    setFilePermissions(dataDir / "overlay/etc/live.conf", {fpUserRead})
    prepareLiveRootfs(rootfs, dataDir, "custom", "/sbin/init")
    check symlinkExists(rootfs / "etc")
    check readFile(rootfs / "usr/etc/live.conf") == "staged only"
    check getFilePermissions(rootfs / "usr/etc/live.conf") == {fpUserRead}

  test "overlays preserve source links and replace destination file links":
    executable(rootfs / "sbin/init")
    createDir(rootfs / "etc")
    let outside = work / "outside"
    writeFile(outside, "do not change")
    createSymlink(outside, rootfs / "etc/live.conf")
    createDir(dataDir / "overlay/etc")
    writeFile(dataDir / "overlay/etc/live.conf", "replacement")
    createDir(work / "source-dir")
    writeFile(work / "source-dir/sentinel", "not copied")
    createSymlink(work / "source-dir", dataDir / "overlay/etc/directory-link")
    createSymlink("/missing/target", dataDir / "overlay/etc/dangling-link")
    prepareLiveRootfs(rootfs, dataDir, "custom", "/sbin/init")
    check readFile(outside) == "do not change"
    check not symlinkExists(rootfs / "etc/live.conf")
    check readFile(rootfs / "etc/live.conf") == "replacement"
    check symlinkExists(rootfs / "etc/directory-link")
    check expandSymlink(rootfs / "etc/directory-link") == work / "source-dir"
    check symlinkExists(rootfs / "etc/dangling-link")
    check expandSymlink(rootfs / "etc/dangling-link") == "/missing/target"

  test "init metadata cannot select overlays outside the data directory":
    for name in ["..", "../systemd", "/systemd", "systemd/../../overlay"]:
      check initOverlayPath(dataDir, name) == ""
    check initOverlayPath(dataDir, "unknown-init") == dataDir / "overlays/unknown-init"

  test "dracut uses shell init and retains live boot and kernel modules":
    let args = liveDracutArgs("6.4.9", "/staging/initramfs.img")
    check args[args.find("--modules") + 1] == "base dmsquash-live kernel-modules"
    check args[args.find("--omit") + 1] == "systemd systemd-initrd"
    check "--no-hostonly" in args
    check "--no-hostonly-cmdline" in args
    check args[args.find("--force-drivers") + 1] == "loop dm_snapshot overlay"
    check args[args.find("--filesystems") + 1] == "ext4 squashfs iso9660"
    check args[args.find("--kver") + 1] == "6.4.9"
    check args[^1] == "/staging/initramfs.img"
    check "--kmoddir" notin args
    check "--kernel-image" notin args
    check "--confdir" notin args

  test "dracut uses selected target paths and isolated configuration":
    let args = liveDracutArgs("6.12.1", "/staging/initramfs.img",
      "/staging/root/lib/modules/6.12.1", "/staging/root/boot/vmlinuz-6.12.1",
      "/staging/dracut.conf.d")
    check args[args.find("--kver") + 1] == "6.12.1"
    check args[args.find("--kmoddir") + 1] == "/staging/root/lib/modules/6.12.1"
    check args[args.find("--kernel-image") + 1] == "/staging/root/boot/vmlinuz-6.12.1"
    check args[args.find("--conf") + 1] == "/dev/null"
    check args[args.find("--confdir") + 1] == "/staging/dracut.conf.d"
    check args[^1] == "/staging/initramfs.img"

  test "dracut refuses implicit running-kernel or output defaults":
    expect ValueError: discard liveDracutArgs("", "/staging/initramfs.img")
    expect ValueError: discard liveDracutArgs("6.12.1", "")

  test "GRUB selects final-root init, not initramfs init":
    let templateText = readFile(currentSourcePath().parentDir / "../../krep/data/iso/grub.cfg")
    let cfg = liveGrubConfig(templateText, "/opt/custom/init")
    check "init=/opt/custom/init" in cfg
    check "rdinit=" notin cfg
    check "@INIT@" notin cfg
    check "root=live:LABEL=ISOIMAGE" in cfg
    check "rd.live.image rw init=" in cfg
    check "linux /boot/vmlinuz " in cfg
    check "initrd /boot/initramfs.img" in cfg
    check "6.4.9" notin cfg

  test "GRUB requires an init placeholder":
    expect ValueError: discard liveGrubConfig("linux /vmlinuz", "/sbin/init")
