import std/[strutils, unittest]
import ../../kickoff/modules/iso9660

proc sectorWith(id: string): string =
  ## Build a 2048-byte Primary Volume Descriptor carrying `id`.
  result = newString(sectorSize)
  result[0] = '\x01'
  result[1 .. 5] = "CD001"
  result[6] = '\x01'
  let padded = id & repeat(' ', volumeIdLength - id.len)
  result[volumeIdOffset ..< volumeIdOffset + volumeIdLength] = padded

suite "iso9660 volume identifier":
  test "reads the volume id from a PVD":
    check isoVolumeId(sectorWith("ISOIMAGE")) == "ISOIMAGE"

  test "strips the space padding":
    check isoVolumeId(sectorWith("MY_LIVE_MEDIA")) == "MY_LIVE_MEDIA"
    # exactly 32 characters needs no padding
    check isoVolumeId(sectorWith("A".repeat(32))) == "A".repeat(32)

  test "rejects a sector without the CD001 signature":
    var s = sectorWith("ISOIMAGE")
    s[1] = 'X'
    check isoVolumeId(s) == ""

  test "rejects a non-primary descriptor":
    var s = sectorWith("ISOIMAGE")
    s[0] = '\x02'          # supplementary volume descriptor
    check isoVolumeId(s) == ""

  test "rejects a short read":
    check isoVolumeId("too short") == ""
    check isoVolumeId(newString(sectorSize - 1)) == ""

  test "pvd offset is sector 16":
    check pvdOffset == 32768

  test "isPvd requires 2048 bytes":
    check isPvd(sectorWith("X"))
    check not isPvd(sectorWith("X")[0 ..< 100])
