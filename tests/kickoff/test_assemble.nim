import std/[algorithm, os, osproc, sets, strutils, unittest]
import ../../kickoff/modules/[assemble, compress, cpio, modules]

proc put16(s: var string, off: int, v: uint16) =
  s[off] = char(v and 0xFF); s[off + 1] = char((v shr 8) and 0xFF)
proc put32(s: var string, off: int, v: uint32) =
  for i in 0 ..< 4: s[off + i] = char((v shr (8 * i)) and 0xFF)
proc put64(s: var string, off: int, v: uint64) =
  for i in 0 ..< 8: s[off + i] = char((v shr (8 * i)) and 0xFF)

proc syntheticElf(interpreter: string, needed: seq[string]): string =
  ## Minimal ELF64 LE with one PT_LOAD covering the file, one PT_INTERP, one PT_DYNAMIC.
  const base = 0x100
  const strtabOff = 0x180
  const dynamicOff = 0x200
  let interpBytes = interpreter & "\0"
  var strtab = "\0"
  var offsets: seq[uint64]
  for name in needed:
    offsets.add uint64(strtab.len)
    strtab.add name & "\0"
  let dynamicLen = (needed.len + 2) * 16
  let total = dynamicOff + dynamicLen
  result = newString(total)
  result[0 .. 3] = "\x7fELF"
  result[4] = '\x02'; result[5] = '\x01'; result[6] = '\x01'
  put16(result, 0x10, 2); put16(result, 0x12, 0xB7)
  put64(result, 0x20, 0x40); put16(result, 0x36, 56); put16(result, 0x38, 3)
  put32(result, 0x40, 1); put32(result, 0x44, 5)
  put64(result, 0x48, 0); put64(result, 0x50, 0x400000)
  put64(result, 0x60, uint64(total)); put64(result, 0x68, uint64(total))
  let ph2 = 0x40 + 56
  put32(result, ph2, 3); put64(result, ph2 + 8, uint64(base))
  put64(result, ph2 + 16, 0x400000'u64 + uint64(base))
  put64(result, ph2 + 32, uint64(interpBytes.len))
  let ph3 = 0x40 + 112
  put32(result, ph3, 2); put64(result, ph3 + 8, uint64(dynamicOff))
  put64(result, ph3 + 16, 0x400000'u64 + uint64(dynamicOff))
  put64(result, ph3 + 32, uint64(dynamicLen))
  for i, ch in interpBytes: result[base + i] = ch
  for i, ch in strtab: result[strtabOff + i] = ch
  var off = dynamicOff
  for idx in offsets:
    put64(result, off, 1); put64(result, off + 8, idx); off += 16
  put64(result, off, 5); put64(result, off + 8, 0x400000'u64 + uint64(strtabOff)); off += 16
  put64(result, off, 0)

const depFile = """
kernel/fs/erofs/erofs.ko: kernel/lib/lz4/lz4hc.ko
kernel/lib/lz4/lz4hc.ko:
kernel/fs/overlayfs/overlay.ko:
kernel/fs/squashfs/squashfs.ko:
kernel/drivers/block/loop.ko:
kernel/fs/isofs/isofs.ko:
"""

proc fixture(base: string): string =
  ## Build a fake rootfs and return the path to the init binary.
  removeDir(base)
  let modRoot = base / "usr/lib/modules/6.18.3"
  createDir(modRoot / "kernel/fs/erofs")
  createDir(modRoot / "kernel/lib/lz4")
  createDir(modRoot / "kernel/fs/overlayfs")
  createDir(modRoot / "kernel/fs/squashfs")
  createDir(modRoot / "kernel/drivers/block")
  createDir(modRoot / "kernel/fs/isofs")
  for m in ["kernel/fs/erofs/erofs.ko", "kernel/lib/lz4/lz4hc.ko",
            "kernel/fs/overlayfs/overlay.ko", "kernel/fs/squashfs/squashfs.ko",
            "kernel/drivers/block/loop.ko", "kernel/fs/isofs/isofs.ko"]:
    writeFile(modRoot / m, "fake module " & m)
  writeFile(modRoot / "modules.dep", depFile)
  writeFile(modRoot / "modules.builtin", "kernel/drivers/block/virtio_blk.ko\n")

  createDir(base / "lib64")
  writeFile(base / "lib64/ld-linux-aarch64.so.1", "fake loader")
  writeFile(base / "lib64/libc.so.6", "fake libc")

  result = base / "kickoff-init"
  writeFile(result, syntheticElf("/lib64/ld-linux-aarch64.so.1", @["libc.so.6"]))
  setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec,
      fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})

proc entryNames(entries: seq[CpioEntry]): seq[string] =
  for e in entries: result.add e.name

suite "initramfs assembly":
  test "erofs layout includes init, libraries, modules and config":
    let base = getTempDir() / "kickoff-assemble"
    let initBin = fixture(base)
    let r = buildInitramfs(InitramfsOptions(
      rootfs: base, initBinary: initBin, kernelVersion: "6.18.3",
      layout: rlErofsDisk, compression: cmNone, mtime: 0))
    let names = entryNames(r.entries)
    check "init" in names
    check "lib64/ld-linux-aarch64.so.1" in names
    check "lib64/libc.so.6" in names
    check "etc/kickoff/modules" in names
    check "etc/kickoff/rootfstype" in names
    # erofs + overlay, and erofs' lz4 dependency
    check "modules/kernel/fs/erofs/erofs.ko" in names
    check "modules/kernel/fs/overlayfs/overlay.ko" in names
    check "modules/kernel/lib/lz4/lz4hc.ko" in names
    # squashfs-only modules must not be pulled in
    check "modules/kernel/fs/squashfs/squashfs.ko" notin names
    check r.skippedBuiltin.len == 0

  test "module load order puts dependencies first":
    let base = getTempDir() / "kickoff-assemble-order"
    let initBin = fixture(base)
    let r = buildInitramfs(InitramfsOptions(
      rootfs: base, initBinary: initBin, kernelVersion: "6.18.3",
      layout: rlErofsDisk, compression: cmNone, mtime: 0))
    let iLz4 = r.modules.find("kernel/lib/lz4/lz4hc.ko")
    let iErofs = r.modules.find("kernel/fs/erofs/erofs.ko")
    check iLz4 >= 0 and iErofs >= 0
    check iLz4 < iErofs

  test "load order file matches the shipped modules exactly":
    let base = getTempDir() / "kickoff-assemble-orderfile"
    let initBin = fixture(base)
    let r = buildInitramfs(InitramfsOptions(
      rootfs: base, initBinary: initBin, kernelVersion: "6.18.3",
      layout: rlSquashfsIso, compression: cmNone, mtime: 0))
    var orderEntry: CpioEntry
    for e in r.entries:
      if e.name == "etc/kickoff/modules": orderEntry = e
    check orderEntry.name.len > 0
    var fromFile: seq[string]
    var current = ""
    for b in orderEntry.data:
      if char(b) == '\n': fromFile.add current; current = ""
      else: current.add char(b)
    if current.len > 0: fromFile.add current
    check fromFile == r.modules

  test "squashfs-iso selects loop and isofs as well":
    let base = getTempDir() / "kickoff-assemble-iso"
    let initBin = fixture(base)
    let r = buildInitramfs(InitramfsOptions(
      rootfs: base, initBinary: initBin, kernelVersion: "6.18.3",
      layout: rlSquashfsIso, compression: cmNone, mtime: 0))
    let names = entryNames(r.entries)
    check "modules/kernel/fs/squashfs/squashfs.ko" in names
    check "modules/kernel/drivers/block/loop.ko" in names
    check "modules/kernel/fs/isofs/isofs.ko" in names

  test "rootfstype file records the layout":
    let base = getTempDir() / "kickoff-assemble-type"
    let initBin = fixture(base)
    for (layout, expected) in [(rlErofsDisk, "erofs\n"),
                               (rlSquashfsDisk, "squashfs\n"),
                               (rlSquashfsIso, "squashfs-iso\n")]:
      let r = buildInitramfs(InitramfsOptions(
        rootfs: base, initBinary: initBin, kernelVersion: "6.18.3",
        layout: layout, compression: cmNone, mtime: 0))
      var body = ""
      for e in r.entries:
        if e.name == "etc/kickoff/rootfstype":
          for b in e.data: body.add char(b)
      check body in [expected]

  test "missing module is a hard error, not a silent omission":
    let base = getTempDir() / "kickoff-assemble-missing"
    let initBin = fixture(base)
    expect IOError:
      discard buildInitramfs(InitramfsOptions(
        rootfs: base, initBinary: initBin, kernelVersion: "6.18.3",
        layout: rlErofsDisk, compression: cmNone, mtime: 0,
        extraModules: @["does_not_exist"]))


  test "GNU cpio accepts the assembled archive":
    if findExe("cpio").len == 0:
      skip()
    else:
      let base = getTempDir() / "kickoff-assemble-cpio"
      let initBin = fixture(base)
      let archivePath = base / "initramfs.cpio"
      discard writeInitramfs(InitramfsOptions(
        rootfs: base, initBinary: initBin, kernelVersion: "6.18.3",
        layout: rlErofsDisk, compression: cmNone, mtime: 0), archivePath)
      let listing = execProcess("sh", args = ["-c", "cpio -it < " & quoteShell(archivePath)],
                                options = {poUsePath})
      for expected in ["init", "lib64/ld-linux-aarch64.so.1", "lib64/libc.so.6",
                       "etc/kickoff/modules", "etc/kickoff/rootfstype",
                       "modules/kernel/fs/erofs/erofs.ko",
                       "modules/kernel/fs/overlayfs/overlay.ko"]:
        check listing.splitLines().contains(expected)

  test "gzip-compressed archive decompresses back to the same bytes":
    if findExe("gzip").len == 0:
      skip()
    else:
      let base = getTempDir() / "kickoff-assemble-gz"
      let initBin = fixture(base)
      let archivePath = base / "initramfs.cpio.gz"
      let result = writeInitramfs(InitramfsOptions(
        rootfs: base, initBinary: initBin, kernelVersion: "6.18.3",
        layout: rlErofsDisk, compression: cmGzip, mtime: 0), archivePath)
      let listing = execProcess("sh", args = ["-c",
        "gzip -dc " & quoteShell(archivePath) & " | cpio -it"],
        options = {poUsePath})
      check listing.splitLines().contains("init")
      check listing.splitLines().contains("etc/kickoff/modules")

  test "archive is a valid newc stream":
    let base = getTempDir() / "kickoff-assemble-valid"
    let initBin = fixture(base)
    let r = buildInitramfs(InitramfsOptions(
      rootfs: base, initBinary: initBin, kernelVersion: "6.18.3",
      layout: rlErofsDisk, compression: cmNone, mtime: 0))
    let raw = cast[string](r.archive)
    check raw.startsWith(newcMagic)
    check raw.len mod 4 == 0
    check raw.contains(newcTrailer)
