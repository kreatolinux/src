import std/[os, strutils, tempfiles, unittest, sequtils]
import ../../krep/modules/[isobuilder, isoworkspace]

const templateText = "linux /boot/vmlinuz init=@INIT@\ninitrd /boot/initramfs.img\n"
proc fixture(base: string): IsoOptions =
  let rootfs = base / "input"
  createDir(rootfs / "sbin")
  createDir(rootfs / "etc")
  createDir(rootfs / "boot")
  createDir(rootfs / "usr/lib/modules/6.12-test")
  writeFile(rootfs / "sbin/init", "#!/bin/sh\n")
  setFilePermissions(rootfs / "sbin/init", {fpUserRead, fpUserExec})
  writeFile(rootfs / "etc/shadow", "root:original:1:0:99999:7:::\n")
  writeFile(rootfs / "usr/lib/modules/6.12-test/modules.dep", "")
  writeFile(rootfs / "boot/vmlinuz-6.12-test", "fixture-kernel")
  let resources = base / "data"
  createDir(resources)
  writeFile(resources / "grub.cfg", templateText)
  writeFile(base / "initramfs", "fixture-initramfs")
  createDir(base / "work")
  result = IsoOptions(rootfs: rootfs, output: base / "output",
      resources: resources, init: "/sbin/init", initramfs: base / "initramfs",
      workDir: base / "work",
      name: "test.iso")

suite "safe ISO assembly":
  setup:
    let base = createTempDir("krep-iso-plan-", "")
    var options = fixture(base)
    var commands: seq[string]
    var failAt = ""
    var password = ""
    var dracutArgs: seq[string]
    let fake: IsoRunner = proc(exe: string, args: seq[string]) =
      commands.add(exe)
      if exe == failAt: raise newException(IOError, "injected " & exe & " failure")
      case exe
      of "cp":
        check args[2] == options.rootfs & "/."
        copyDirWithPermissions(options.rootfs, args[^1])
      of "tar": copyDirWithPermissions(base / "input", args[4])
      of "dracut":
        dracutArgs = args
        writeFile(args[^1], "generated-initramfs")
      of "truncate": writeFile(args[^1], "sparse-image")
      of "mkfs.ext4":
        let staged = args[args.find("-d") + 1]
        password = readFile(staged / "etc/shadow")
      of "mksquashfs": writeFile(args[1], "squashfs")
      of "grub-mkrescue":
        let tree = args[2]
        check readFile(tree / "boot/vmlinuz") == "fixture-kernel"
        check fileExists(tree / "boot/initramfs.img")
        check "init=/sbin/init" in readFile(tree / "boot/grub/grub.cfg")
        writeFile(args[1], "fixture-iso")
      else: raise newException(ValueError, "unexpected command " & exe)
  teardown:
    removeDir(base)

  test "directory input needs no release metadata and preserves authentication":
    let output = assembleIso(options, fake)
    check readFile(output) == "fixture-iso"
    check password.startsWith("root:original:")
    check readFile(options.rootfs / "etc/shadow").startsWith("root:original:")
    check commands == @["cp", "truncate", "mkfs.ext4", "mksquashfs", "grub-mkrescue"]
    check toSeq(walkDir(options.workDir)).len == 0
    check not dirExists(output & ".lock")

  test "failure at every external step cleans workspace and lock":
    for stage in ["cp", "truncate", "mkfs.ext4", "mksquashfs", "grub-mkrescue"]:
      failAt = stage
      expect IOError: discard assembleIso(options, fake)
      check toSeq(walkDir(options.workDir)).len == 0
      check not dirExists(options.output / "test.iso.lock")
      check not fileExists(options.output / "test.iso")

  test "dracut uses selected rootfs kernel and modules instead of host boot":
    options.initramfs = ""
    discard assembleIso(options, fake)
    check "dracut" in commands
    check dracutArgs[dracutArgs.find("--kver") + 1] == "6.12-test"
    check "/rootfs/" in dracutArgs[dracutArgs.find("--kmoddir") + 1]
    check "/rootfs/boot/vmlinuz-6.12-test" in dracutArgs[dracutArgs.find(
        "--kernel-image") + 1]
    check "--confdir" in dracutArgs

  test "dracut failure cleans workspace and lock":
    options.initramfs = ""
    failAt = "dracut"
    expect IOError: discard assembleIso(options, fake)
    check toSeq(walkDir(options.workDir)).len == 0
    check not dirExists(options.output / "test.iso.lock")

  test "clearing root password is explicit and staged only":
    options.clearRootPassword = true
    discard assembleIso(options, fake)
    check password.startsWith("root::")
    check readFile(options.rootfs / "etc/shadow").startsWith("root:original:")

  test "existing ISO is not overwritten without explicit permission":
    createDir(options.output)
    writeFile(options.output / "test.iso", "keep")
    expect IOError: discard assembleIso(options, fake)
    check readFile(options.output / "test.iso") == "keep"
    check toSeq(walkDir(options.workDir)).len == 0
    options.overwrite = true
    discard assembleIso(options, fake)
    check readFile(options.output / "test.iso") == "fixture-iso"

  test "tool requirements do not require dracut or udev with supplied initramfs":
    let tools = requiredIsoTools(options)
    for tool in ["mount", "umount", "losetup", "kpkg", "chroot", "dracut", "udevadm"]:
      check tool notin tools
    options.initramfs = ""
    check "dracut" in requiredIsoTools(options)
    check "udevadm" in requiredIsoTools(options)

  test "invalid names and negative image sizes fail before staging":
    for name in ["../escape.iso", "/tmp/out.iso", "bad name.iso", ".hidden.iso",
        "no-extension"]:
      options.name = name
      expect ValueError: validateIsoOptions(options)
    options.name = "valid.iso"
    options.imageSizeMiB = -1
    expect ValueError: validateIsoOptions(options)
    check toSeq(walkDir(options.workDir)).len == 0

  test "image sizing accounts for content instead of fixed one GiB":
    check rootfsImageSizeMiB(options.rootfs) >= 256

  test "input archive uses direct argument array and preserves paths with spaces":
    let archive = base / "input archive.tar"
    writeFile(archive, "fake-archive")
    options.rootfs = archive
    discard assembleIso(options, fake)
    check commands[0] == "tar"

  test "publication cancellation does not leave partial output or locks":
    var checks = 0
    let cancel = proc() =
      inc checks
      if checks > 3: raise newException(IOError, "cancelled publication")
    expect IOError: discard assembleIso(options, fake, cancel)
    check not fileExists(options.output / "test.iso")
    check not dirExists(options.output / "test.iso.lock")
    check toSeq(walkDir(options.workDir)).len == 0
    check toSeq(walkDir(options.output)).len == 0

  test "workspace and output cannot be inside input rootfs":
    options.workDir = options.rootfs
    expect ValueError: validateIsoOptions(options)
    options.workDir = base / "work"
    options.output = options.rootfs / "out"
    expect ValueError: validateIsoOptions(options)
