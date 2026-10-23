import std/[strutils, unittest]
import ../../kickoff/modules/cpio

proc bytesToStr(b: seq[byte]): string =
  result = newString(b.len)
  for i, v in b: result[i] = char(v)

proc hexField(archive: string, index: int): uint32 =
  ## Read field `index` (0-based, after the 6-byte magic) of the header at offset 0.
  let start = 6 + index * 8
  parseHexInt("0x" & archive[start ..< start + 8]).uint32

suite "cpio newc archive":
  test "empty archive is just a trailer":
    let archive = bytesToStr(buildArchive(@[]))
    check archive.startsWith(newcMagic)
    check archive.len mod 4 == 0
    # namesize field is index 11; "TRAILER!!!" is 10 bytes + NUL
    check hexField(archive, 11) == 11'u32

  test "header is 110 bytes and name is NUL terminated":
    let entry = CpioEntry(name: "init", kind: ckFile,
        permissions: 0o755'u32, data: @[byte 1, 2, 3])
    let archive = bytesToStr(buildArchive(@[entry]))
    check archive[0 ..< 6] == newcMagic
    # 13 fields * 8 = 104, so the name starts at 110
    check archive[110 ..< 115] == "init\0"

  test "field encoding: mode carries the file type bits":
    let entry = CpioEntry(name: "init", kind: ckFile, permissions: 0o755'u32)
    let archive = bytesToStr(buildArchive(@[entry]))
    # index 1 is c_mode
    check hexField(archive, 1) == (S_IFREG or 0o755'u32)

  test "field encoding: directory gets S_IFDIR and no payload":
    let entry = CpioEntry(name: "etc", kind: ckDir, permissions: 0o755'u32,
        data: @[byte 9])   # must be ignored
    let archive = bytesToStr(buildArchive(@[entry]))
    check hexField(archive, 1) == (S_IFDIR or 0o755'u32)
    check hexField(archive, 6) == 0'u32       # filesize forced to 0

  test "filesize and namesize are exact":
    let payload = @[byte 0xAA, 0xBB, 0xCC, 0xDD, 0xEE]   # 5 bytes
    let entry = CpioEntry(name: "x", kind: ckFile, data: payload)
    let archive = bytesToStr(buildArchive(@[entry]))
    check hexField(archive, 6) == 5'u32       # filesize
    check hexField(archive, 11) == 2'u32      # namesize = "x" + NUL

  test "every entry starts on a 4-byte boundary":
    let entries = @[
      CpioEntry(name: "a", kind: ckFile, data: @[byte 1]),
      CpioEntry(name: "bb", kind: ckFile, data: @[byte 1, 2]),
      CpioEntry(name: "ccc", kind: ckDir),
    ]
    let archive = bytesToStr(buildArchive(entries))
    check archive.len mod 4 == 0
    var offset = 0
    var seen = 0
    while offset + newcHeaderLen < archive.len:
      check archive[offset ..< offset + 6] == newcMagic
      let namesize = parseHexInt("0x" & archive[offset + 6 + 11 * 8 ..< offset + 6 + 12 * 8])
      let filesize = parseHexInt("0x" & archive[offset + 6 + 6 * 8 ..< offset + 6 + 7 * 8])
      let nameStart = offset + newcHeaderLen
      let name = archive[nameStart ..< nameStart + namesize - 1]
      if name == newcTrailer:
        seen.inc
        break
      # advance: header + name, padded; then data, padded
      let afterName = nameStart + namesize
      let dataStart = afterName + ((4 - (afterName mod 4)) mod 4)
      let dataEnd = dataStart + filesize
      let next = dataEnd + ((4 - (dataEnd mod 4)) mod 4)
      check next mod 4 == 0
      offset = next
    check seen == 1
    # deterministic order: shallower first
    check archive.find("a\0") < archive.find("bb\0")

  test "entry order is stable and parents come first":
    let entries = @[
      CpioEntry(name: "usr/lib/mod", kind: ckFile, data: @[byte 0]),
      CpioEntry(name: "usr", kind: ckDir),
      CpioEntry(name: "usr/lib", kind: ckDir),
      CpioEntry(name: "init", kind: ckFile, data: @[byte 0]),
    ]
    let archive = bytesToStr(buildArchive(entries))
    let iInit = archive.find("init\0")
    let iUsr = archive.find("usr\0")
    let iLib = archive.find("usr/lib\0")
    let iMod = archive.find("usr/lib/mod\0")
    check iInit > 0 and iUsr > 0 and iLib > 0 and iMod > 0
    check iLib < iMod            # parent before child

  test "names are validated":
    expect ValueError:
      discard buildArchive(@[CpioEntry(name: "", kind: ckFile)])
    expect ValueError:
      discard buildArchive(@[CpioEntry(name: "/abs", kind: ckFile)])
    expect ValueError:
      discard buildArchive(@[CpioEntry(name: "../up", kind: ckFile)])

  test "symlink payload is the target, mode is S_IFLNK":
    var link = CpioEntry(name: "bin/sh", kind: ckSymlink, permissions: 0o777'u32)
    let target = "/bin/busybox"
    link.data = newSeq[byte](target.len)
    for i, ch in target: link.data[i] = byte(ch)
    let archive = bytesToStr(buildArchive(@[link]))
    check hexField(archive, 1) == (S_IFLNK or 0o777'u32)
    check hexField(archive, 6) == uint32(target.len)
    check archive.contains(target)
