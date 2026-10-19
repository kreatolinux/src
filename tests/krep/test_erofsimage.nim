import std/[os, strutils, tempfiles, unittest]
import ../../krep/modules/[erofsimage, isobuilder]

proc fixture(base: string): ErofsOptions =
  let rootfs = base / "input"
  createDir(rootfs / "sbin"); createDir(rootfs / "etc"); createDir(rootfs / "boot")
  createDir(rootfs / "usr/bin")
  createDir(rootfs / "usr/lib/modules/6.12-test")
  writeFile(rootfs / "sbin/init", "#!/bin/sh\n")
  setFilePermissions(rootfs / "sbin/init", {fpUserRead, fpUserExec})
  writeFile(rootfs / "usr/lib/modules/6.12-test/modules.dep", "")
  writeFile(rootfs / "boot/vmlinuz-6.12-test", "fixture-kernel")
  writeFile(base / "initramfs", "fixture-initramfs")
  createDir(base / "work")
  ErofsOptions(rootfs: rootfs, output: base / "output", init: "/sbin/init",
      workDir: base / "work", partLabel: "jsroot", name: "t.img",
      initramfs: base / "initramfs", writableMounts: true)

suite "erofs disk image logic":
  test "generator parsing and ISO refusal":
    check parseGenerator("") == igDracut
    check parseGenerator("Booster") == igBooster
    expect ValueError: discard parseGenerator("mkinitcpio")
    validateIsoGenerator("dracut")
    expect ValueError: validateIsoGenerator("booster")
  test "partition label validation":
    validatePartLabel("jsroot")
    for bad in ["", "a b", "x=y", "a".repeat(37), "a/b"]:
      expect ValueError: validatePartLabel(bad)
  test "preflight tools":
    let base = createTempDir("krep-erofs-", "")
    defer: removeDir(base)
    var o = fixture(base)
    check "mkfs.erofs" in requiredErofsTools(o)
    check "sgdisk" in requiredErofsTools(o)
    check "dracut" notin requiredErofsTools(o)   # --initramfs supplied
    o.initramfs = ""
    check "dracut" in requiredErofsTools(o)
    o.generator = igBooster
    check "chroot" in requiredErofsTools(o)
    check "dracut" notin requiredErofsTools(o)
    o.rootfs = base / "x.tar"
    check "tar" in requiredErofsTools(o)
  test "command lines":
    check boosterArgs("6.1", "/i.img") ==
      @["build", "--force", "--universal", "--kernel-version", "6.1", "/i.img"]
    check boosterChrootArgs("/r", "6.1", "/i.img")[0 .. 1] == @["/r", "booster"]
    expect ValueError: discard boosterArgs("", "/i")
    expect ValueError: discard boosterArgs("6.1", "i")
    check mkfsErofsArgs("jsroot", "o", "s") == @["-zlz4hc,9", "-L", "jsroot", "o", "s"]
    check sgdiskArgs("d", "jsroot") == @["-o", "-n", "1:2048:0", "-t", "1:8300", "-c", "1:jsroot", "d"]
    check "seek=2048" in ddArgs("a", "b")
    let d = erofsDracutArgs("6.1", "out", "/m", "/k", "/c")
    check "erofs" in d and "dmsquash-live" notin d.join(" ") and d[^1] == "out"
    expect ValueError: discard erofsDracutArgs("", "out")
  test "disk size and cmdline":
    check diskSizeBytes(1) == 5 * 1048576
    check diskSizeBytes(2 * 1048576) == 6 * 1048576
    check erofsKernelCmdline("jsroot", "/usr/bin/jumpstart", "console=ttyS0") ==
      "root=PARTLABEL=jsroot rootfstype=erofs ro init=/usr/bin/jumpstart console=ttyS0"
    expect ValueError: discard erofsKernelCmdline("jsroot", "init")
    check erofsOutputNames("/o/a.img").initramfs == "/o/a.initramfs.img"
  test "writable mounts are appended once":
    let base = createTempDir("krep-erofs-", "")
    defer: removeDir(base)
    createDir(base / "etc")
    writeFile(base / "etc/fstab", "/dev/x / ext4 defaults 0 1")
    installWritableMounts(base)
    installWritableMounts(base)
    let text = readFile(base / "etc/fstab")
    check text.startsWith("/dev/x / ext4 defaults 0 1\n")
    check text.count("tmpfs /var tmpfs") == 1
    for p in ["/tmp", "/root", "/home"]: check ("tmpfs " & p & " ") in text
  test "validation errors":
    let base = createTempDir("krep-erofs-", "")
    defer: removeDir(base)
    var o = fixture(base)
    validateErofsOptions(o)
    var b = o; b.name = "x.iso"
    expect ValueError: validateErofsOptions(b)
    b = o; b.partLabel = "bad label"
    expect ValueError: validateErofsOptions(b)
    b = o; b.rootfs = base / "none"
    expect ValueError: validateErofsOptions(b)
    b = o; b.init = "sbin/init"
    expect ValueError: validateErofsOptions(b)
  test "assembly with fake runner":
    let base = createTempDir("krep-erofs-", "")
    defer: removeDir(base)
    var o = fixture(base)
    var cmds: seq[string]
    var chrootArgs: seq[string]
    let fake: IsoRunner = proc(exe: string, args: seq[string]) =
      cmds.add(exe)
      case exe
      of "mkfs.erofs": writeFile(args[^2], "erofs")
      of "truncate": writeFile(args[^1], "disk")
      of "chroot":
        chrootArgs = args
        writeFile(args[0] / "initramfs-krep.img", "booster")
      else: discard
      if exe == "cp": copyDirWithPermissions(o.rootfs, args[^1])
    let image = assembleErofsImage(o, fake)
    check cmds == @["cp", "mkfs.erofs", "truncate", "sgdisk", "dd"]
    check fileExists(image) and fileExists(image[0..^5] & ".vmlinuz")
    check readFile(image[0..^5] & ".initramfs.img") == "fixture-initramfs"
    check readFile(image[0..^5] & ".cmdline").startsWith("root=PARTLABEL=jsroot")
    # existing outputs refused without overwrite
    expect IOError: discard assembleErofsImage(o, fake)
    # booster needs the binary in the rootfs
    var bo = o; bo.initramfs = ""; bo.generator = igBooster; bo.overwrite = true
    expect ValueError: discard assembleErofsImage(bo, fake)
    writeFile(o.rootfs / "usr/bin/booster", "x")
    cmds = @[]
    discard assembleErofsImage(bo, fake)
    check cmds[1] == "chroot" and chrootArgs[1] == "booster"
    check readFile(image[0..^5] & ".initramfs.img") == "booster"

suite "erofs bootable (UEFI GRUB) logic":
  test "parsing and arch mapping":
    check parseBootLoader("") == blNone and parseBootLoader("GRUB") == blGrub
    expect ValueError: discard parseBootLoader("lilo")
    check parseBootArch("arm64") == baAarch64 and parseBootArch("amd64") == baX86_64
    expect ValueError: discard parseBootArch("riscv64")
    check grubTarget(baAarch64) == "arm64-efi" and grubTarget(baX86_64) == "x86_64-efi"
    check efiFallbackName(baAarch64) == "BOOTAA64.EFI"
    check efiFallbackName(baX86_64) == "BOOTX64.EFI"
    check grubPlatformDir(baAarch64) == "/usr/lib/grub/arm64-efi"
  test "ELF architecture detection":
    var h = "\x7fELF\x02\x01\x01" & "\0".repeat(11) & "\xB7\x00"
    check archFromElfHeader(h) == baAarch64
    h[18] = '\x3E'
    check archFromElfHeader(h) == baX86_64
    h[18] = '\x08'
    expect ValueError: discard archFromElfHeader(h)
    expect ValueError: discard archFromElfHeader("#!/bin/sh\n" & "x".repeat(20))
    let base = createTempDir("krep-erofs-", "")
    defer: removeDir(base)
    createDir(base / "sbin")
    writeFile(base / "sbin/init", "\x7fELF\x02\x01\x01" & "\0".repeat(11) & "\x3E\x00")
    check detectRootfsArch(base, "/sbin/init") == baX86_64
    writeFile(base / "sbin/init", "#!/bin/sh\n")
    expect ValueError: discard detectRootfsArch(base, "/sbin/init")
  test "partition plan and command lines":
    check rootStartSector(256) == 2048 + 524288
    check sgdiskBootableArgs("d", "jsroot", 256) ==
      @["-o", "-n", "1:2048:+256M", "-t", "1:EF00", "-c", "1:JSESP",
        "-n", "2:526336:0", "-t", "2:8300", "-c", "2:jsroot", "d"]
    check "seek=526336" in ddArgs("a", "b", rootStartSector(256))
    check mkfsVfatArgs("e.img") == @["-F", "32", "-n", "JSESP", "e.img"]
    check mcopyArgs("e.img", @["/x/EFI", "/x/boot"]) ==
      @["-i", "e.img", "-s", "-p", "-Q", "/x/EFI", "/x/boot", "::/"]
    let g = grubStandaloneArgs(baAarch64, "/o/BOOTAA64.EFI", "/e.cfg")
    check g[0] == "--format=arm64-efi" and g[1] == "--output=/o/BOOTAA64.EFI"
    check g[^1] == "boot/grub/grub.cfg=/e.cfg" and "--modules=" & grubModules in g
    check diskSizeBytes(1, 256) == 261 * 1048576
  test "grub.cfg and command line text":
    let cmd = bootCmdline("jsroot", "/usr/bin/jumpstart", "tty0 ttyAMA0,115200", "quiet loglevel=3")
    check cmd == "root=PARTLABEL=jsroot rootfstype=erofs ro init=/usr/bin/jumpstart " &
      "console=tty0 console=ttyAMA0,115200 quiet loglevel=3"
    check bootCmdline("jsroot", "/sbin/init", "", "") ==
      erofsKernelCmdline("jsroot", "/sbin/init")
    let cfg = espGrubConfig("/boot/vmlinuz-6.12", "/boot/initramfs-6.12.img", cmd, "tty0 ttyAMA0,115200")
    check "linux /boot/vmlinuz-6.12 " & cmd & "\n" in cfg
    check "initrd /boot/initramfs-6.12.img\n" in cfg
    check "serial " notin cfg and "set timeout=3" in cfg
    let x86 = espGrubConfig("/boot/v", "/boot/i", cmd, "ttyS1,9600")
    check "serial --unit=1 --speed=9600\nterminal_input serial console" in x86
    expect ValueError: discard espGrubConfig("boot/v", "/boot/i", cmd, "")
    expect ValueError: discard espGrubConfig("/boot/v", "/boot/i", "a\"b", "")
    check espEmbeddedConfig() ==
      "search --no-floppy --label JSESP --set=root\nconfigfile ($root)/boot/grub/grub.cfg\n"
  test "option validation and preflight":
    let base = createTempDir("krep-erofs-", "")
    defer: removeDir(base)
    var o = fixture(base)
    check "mkfs.vfat" notin requiredErofsTools(o)
    o.bootloader = blGrub
    for t in ["mkfs.vfat", "mcopy", "grub-mkstandalone"]: check t in requiredErofsTools(o)
    validateErofsOptions(o)
    var b = o; b.arch = "mips"
    expect ValueError: validateErofsOptions(b)
    b = o; b.espSizeMiB = 10
    expect ValueError: validateErofsOptions(b)
    b = o; b.console = "console=ttyS0"
    expect ValueError: validateErofsOptions(b)
    b = o; b.kernelArgs = "a;b"
    expect ValueError: validateErofsOptions(b)
    b = fixture(base / "b"); b.console = "ttyS0"      # without a bootloader
    expect ValueError: validateErofsOptions(b)
    b.console = ""; b.arch = "x86_64"
    expect ValueError: validateErofsOptions(b)
  test "bootable assembly with fake runner":
    let base = createTempDir("krep-erofs-", "")
    defer: removeDir(base)
    var o = fixture(base)
    o.bootloader = blGrub; o.arch = "x86_64"; o.console = "ttyS0,115200"
    o.espSizeMiB = 64
    var calls: seq[(string, seq[string])]
    var cfgSeen = ""
    let fake: IsoRunner = proc(exe: string, args: seq[string]) =
      calls.add((exe, args))
      case exe
      of "mkfs.erofs": writeFile(args[^2], "erofs")
      of "truncate": writeFile(args[^1], "x")
      of "grub-mkstandalone":
        writeFile(args[1]["--output=".len .. ^1], "efi")
      of "mcopy":
        cfgSeen = readFile(args[^2].parentDir / "boot/grub/grub.cfg")
      of "cp": copyDirWithPermissions(o.rootfs, args[^1])
      else: discard
    let image = assembleErofsImage(o, fake)
    var names: seq[string]
    for c in calls: names.add(c[0])
    check names == @["cp", "mkfs.erofs", "grub-mkstandalone", "truncate",
      "mkfs.vfat", "mcopy", "truncate", "sgdisk", "dd", "dd"]
    check calls[2][1][0] == "--format=x86_64-efi"
    check "BOOTX64.EFI" in calls[2][1][1]
    check calls[7][1][6] == "1:JSESP"
    check "seek=2048" in calls[8][1] and "seek=" & $rootStartSector(64) in calls[9][1]
    check "linux /boot/vmlinuz-6.12-test root=PARTLABEL=jsroot" in cfgSeen
    check "console=ttyS0,115200" in cfgSeen and "serial --unit=0 --speed=115200" in cfgSeen
    check readFile(image[0..^5] & ".cmdline").endsWith("console=ttyS0,115200\n")
    # a too small ESP is refused
    var small = o; small.overwrite = true
    writeFile(base / "initramfs", "x".repeat(70 * 1048576))
    expect ValueError: discard assembleErofsImage(small, fake)
    # missing platform files are an explicit error
    small = o; small.overwrite = true; small.verifyGrubDir = true
    small.arch = "x86_64"
    if not dirExists(grubPlatformDir(baX86_64)):
      expect OSError: discard assembleErofsImage(small, fake)
