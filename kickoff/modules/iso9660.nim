## Just enough ISO9660 to identify live media.
##
## An initramfs cannot use /dev/disk/by-label: that directory is created by udev,
## which does not run before the real root exists. The volume label is instead
## read straight out of the Primary Volume Descriptor, which is what blkid does.
##
## Layout (ECMA-119): the PVD is at logical sector 16 (2048-byte sectors), and the
## 32-byte volume identifier sits at offset 40 within it, space padded.

import std/strutils

const
  sectorSize* = 2048
  pvdSector* = 16
  pvdOffset* = pvdSector * sectorSize     ## 32768
  volumeIdOffset* = 40
  volumeIdLength* = 32

proc isPvd*(sector: string): bool =
  ## A Primary Volume Descriptor is identified by "CD001" at offset 1 and type 1.
  sector.len >= sectorSize and
    sector.len > volumeIdOffset and
    sector[0] == '\x01' and
    sector[1 .. 5] == "CD001"

proc isoVolumeId*(sector: string): string =
  ## The volume identifier from a 2048-byte sector, or "" when the sector is not
  ## a Primary Volume Descriptor. Trailing spaces are stripped, as the field is
  ## space padded to its fixed width.
  if sector.len < volumeIdOffset + volumeIdLength: return ""
  if not isPvd(sector): return ""
  result = sector[volumeIdOffset ..< volumeIdOffset + volumeIdLength]
  result = result.strip(leading = false, chars = {' ', '\0'})
