import std/[algorithm, os, strutils, tempfiles, unittest]
import ../../kickoff/modules/libs

proc put16(s: var string, off: int, v: uint16) =
  s[off] = char(v and 0xFF)
  s[off + 1] = char((v shr 8) and 0xFF)

proc put32(s: var string, off: int, v: uint32) =
  for i in 0 ..< 4: s[off + i] = char((v shr (8 * i)) and 0xFF)

proc put64(s: var string, off: int, v: uint64) =
  for i in 0 ..< 8: s[off + i] = char((v shr (8 * i)) and 0xFF)

proc buildElf(interpreter: string, needed: seq[string]): string =
  ## A minimal ELF64 LE image with one PT_LOAD covering the whole file (so
  ## vaddr == 0x400000 + file offset), one PT_INTERP and one PT_DYNAMIC.
  const
    base = 0x100
    strtabOff = 0x180
    dynamicOff = 0x200
  let interpBytes = interpreter & "\0"
  var strtab = "\0"
  var neededOffsets: seq[uint64]
  for name in needed:
    neededOffsets.add uint64(strtab.len)
    strtab.add name & "\0"
  let dynamicLen = (needed.len + 2) * 16      # NEEDED*, STRTAB, NULL
  let total = dynamicOff + dynamicLen

  result = newString(total)
  # e_ident
  result[0 .. 3] = "\x7fELF"
  result[4] = '\x02'          # ELFCLASS64
  result[5] = '\x01'          # little endian
  result[6] = '\x01'          # EV_CURRENT
  put16(result, 0x10, 2)      # e_type = ET_EXEC
  put16(result, 0x12, 0xB7)   # e_machine = aarch64
  put64(result, 0x20, 0x40)   # e_phoff
  put16(result, 0x36, 56)     # e_phentsize
  put16(result, 0x38, 3)      # e_phnum

  # PT_LOAD
  put32(result, 0x40, 1)
  put32(result, 0x40 + 4, 5)
  put64(result, 0x40 + 8, 0)
  put64(result, 0x40 + 16, 0x400000)
  put64(result, 0x40 + 32, uint64(total))
  put64(result, 0x40 + 40, uint64(total))
  # PT_INTERP
  let ph2 = 0x40 + 56
  put32(result, ph2, 3)
  put64(result, ph2 + 8, uint64(base))
  put64(result, ph2 + 16, 0x400000'u64 + uint64(base))
  put64(result, ph2 + 32, uint64(interpBytes.len))
  # PT_DYNAMIC
  let ph3 = 0x40 + 112
  put32(result, ph3, 2)
  put64(result, ph3 + 8, uint64(dynamicOff))
  put64(result, ph3 + 16, 0x400000'u64 + uint64(dynamicOff))
  put64(result, ph3 + 32, uint64(dynamicLen))

  for i, ch in interpBytes: result[base + i] = ch
  for i, ch in strtab: result[strtabOff + i] = ch

  var off = dynamicOff
  for idx in neededOffsets:
    put64(result, off, 1)                 # DT_NEEDED
    put64(result, off + 8, idx)
    off += 16
  put64(result, off, 5)                   # DT_STRTAB
  put64(result, off + 8, 0x400000'u64 + uint64(strtabOff))
  off += 16
  put64(result, off, 0)                   # DT_NULL

suite "elf library resolution":
  test "parses interpreter and DT_NEEDED from a synthetic ELF":
    let elf = buildElf("/lib/ld-linux-aarch64.so.1", @["libc.so.6", "libm.so.6"])
    let info = parseElf(elf)
    check info.interpreter == "/lib/ld-linux-aarch64.so.1"
    check info.needed == @["libc.so.6", "libm.so.6"]

  test "rejects non-ELF and wrong class":
    expect ElfError: discard parseElf("not an elf at all")
    var elf = buildElf("/lib/ld.so", @["libc.so.6"])
    elf[4] = '\x01'          # ELFCLASS32
    expect ElfError: discard parseElf(elf)

  test "search path includes /lib64":
    # Regression guard: Kreato Linux installs its runtime objects in /lib64,
    # and leaving it out is what made booster fail to generate an initramfs at
    # all.
    check "/lib64" in defaultSearchDirs()
    check "/usr/lib64" in defaultSearchDirs()

  test "resolveSoname finds a library under /lib64":
    let root = getTempDir() / "kickoff-libs"
    removeDir(root)
    createDir(root / "lib64")
    writeFile(root / "lib64/libc.so.6", "fake")
    check resolveSoname(root, "libc.so.6") == "/lib64/libc.so.6"
    check resolveSoname(root, "libnope.so.1") == ""

  test "libraryClosure reports missing libraries instead of dropping them":
    let root = getTempDir() / "kickoff-libs-closure"
    removeDir(root)
    createDir(root / "lib64")
    createDir(root / "lib")
    writeFile(root / "lib64/ld-linux-aarch64.so.1", "fake-loader")
    writeFile(root / "lib64/libc.so.6", buildElf("", @[]))
    let bin = root / "jumpstart"
    writeFile(bin, buildElf("/lib64/ld-linux-aarch64.so.1", @["libc.so.6", "libabsent.so.9"]))
    let closure = libraryClosure(root, @[bin])
    check closure.interpreter == "/lib64/ld-linux-aarch64.so.1"
    check closure.missing == @["libabsent.so.9"]
    var paths: seq[string]
    for c in closure.copies: paths.add c.archivePath
    paths.sort()
    check "/lib64/libc.so.6" in paths
    check "/lib64/ld-linux-aarch64.so.1" in paths
