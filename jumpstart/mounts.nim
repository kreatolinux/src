## Direct mount syscalls for Jumpstart
##
## Minimal wrapper around mount(2)/umount2(2) for init system use.

import posix
import strutils

# Mount flags
const
  MS_RDONLY* = 1.culong
  MS_NOSUID* = 2.culong
  MS_NODEV* = 4.culong
  MS_NOEXEC* = 8.culong
  MS_REMOUNT* = 32.culong
  MS_NOATIME* = 1024.culong
  MS_BIND* = 4096.culong
  MS_REC* = 16384.culong

# Umount flags
const
  MNT_DETACH* = 2.cint # Lazy unmount

# Syscalls
proc mount(source, target, fstype: cstring, flags: culong, data: pointer): cint
  {.importc, header: "<sys/mount.h>".}

proc umount2(target: cstring, flags: cint): cint
  {.importc, header: "<sys/mount.h>".}

proc strerror(errnum: cint): cstring
  {.importc, header: "<string.h>".}

proc mountFs*(source, target, fstype: string, flags: culong = 0,
    data: string = ""): int =
  ## Mount a filesystem. Returns 0 on success, errno on failure.
  let dataPtr = if data.len > 0: data.cstring else: nil
  if mount(source.cstring, target.cstring, fstype.cstring, flags, dataPtr) != 0:
    return errno.int
  return 0

proc umountFs*(target: string, flags: cint = 0): int =
  ## Unmount a filesystem. Returns 0 on success, errno on failure.
  if umount2(target.cstring, flags) != 0:
    return errno.int
  return 0

proc mountErrorStr*(errnum: int): string =
  ## Get error string for errno.
  if errnum == 0: "Success" else: $strerror(errnum.cint)

proc isMounted*(target: string): bool =
  ## Check if path is mounted by reading /proc/mounts.
  try:
    for line in lines("/proc/mounts"):
      let spaceIdx = line.find(' ', line.find(' ') + 1)
      if spaceIdx > 0:
        let mountPoint = line[line.find(' ') + 1 ..< spaceIdx]
        if mountPoint == target:
          return true
  except IOError:
    discard
  return false
