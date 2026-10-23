## Direct mount syscalls.
##
## Moved here from jumpstart/mounts.nim so that anything which needs to mount a
## filesystem — the daemon's PID 1 duties, native mount units, and an initramfs
## init — shares one tested implementation instead of growing its own copy.
##
## The Linux build binds mount(2)/umount2(2) directly. Other platforms (macOS
## development hosts) get stubs that fail with ENOSYS, so the native backend and
## its tests still compile and test the surrounding logic.

import std/strutils

when defined(linux):
  import posix

  # Mount flags
  const
    MS_RDONLY* = 1.culong
    MS_NOSUID* = 2.culong
    MS_NODEV* = 4.culong
    MS_NOEXEC* = 8.culong
    MS_REMOUNT* = 32.culong
    MS_NOATIME* = 1024.culong
    MS_BIND* = 4096.culong
    MS_MOVE* = 8192.culong      ## move a mounted tree (switch_root)
    MS_REC* = 16384.culong

  # Umount flags
  const
    MNT_DETACH* = 2.cint        ## lazy unmount

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

else:
  import posix

  const
    MS_RDONLY* = 1.culong
    MS_NOSUID* = 2.culong
    MS_NODEV* = 4.culong
    MS_NOEXEC* = 8.culong
    MS_REMOUNT* = 32.culong
    MS_NOATIME* = 1024.culong
    MS_BIND* = 4096.culong
    MS_MOVE* = 8192.culong
    MS_REC* = 16384.culong
    MNT_DETACH* = 2.cint

  proc mountFs*(source, target, fstype: string, flags: culong = 0,
      data: string = ""): int = ENOSYS.int

  proc umountFs*(target: string, flags: cint = 0): int = ENOSYS.int

  proc mountErrorStr*(errnum: int): string =
    if errnum == 0: "Success" else: $strerror(errnum.cint)

  proc isMounted*(target: string): bool = false
