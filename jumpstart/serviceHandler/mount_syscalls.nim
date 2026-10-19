## mount(2)/umount2(2) for native mount units. ../mounts.nim binds the Linux
## syscalls; other platforms (development hosts only) get stubs that fail
## with ENOSYS, so the native backend and its tests still build there.
when defined(linux):
  import ../mounts
  export mounts
else:
  import posix
  const
    MS_REMOUNT* = 32.culong
    MNT_DETACH* = 2.cint
  proc mountFs*(source, target, fstype: string, flags: culong = 0,
                data: string = ""): int = ENOSYS.int
  proc umountFs*(target: string, flags: cint = 0): int = ENOSYS.int
  proc mountErrorStr*(errnum: int): string =
    if errnum == 0: "Success" else: $strerror(errnum.cint)
  proc isMounted*(target: string): bool = false
