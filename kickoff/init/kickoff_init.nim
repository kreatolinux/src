## kickoff-init — PID 1 inside the initramfs.
##
## Job: bring up the minimum to mount the real root, optionally lay an overlay on
## top so the system is writable, then hand control to whatever init the rootfs
## declares. It deliberately knows nothing about jumpstart, systemd or any other
## init: the executable to run comes from `init=` on the kernel command line and
## defaults to /sbin/init.
##
## Deliberately not handled here: LUKS, LVM, RAID, network root, hibernation
## resume. Those need modules and userspace helpers this archive does not carry.
## A root that needs them fails with a clear message rather than hanging.

import std/[os, posix, strutils, tables]

import jumpstartcore/mounts

# Not declared by Nim's posix module, and needed here: chroot(2) for the switch,
# and the raw syscall(2) entry point for finit_module(2), which has no libc
# wrapper.
proc chroot(path: cstring): cint {.importc, header: "<unistd.h>".}
proc syscall(number: clong): clong {.importc, varargs, header: "<unistd.h>".}
proc ioctl(fd: cint, request: culong): cint {.importc, varargs,
                                             header: "<sys/ioctl.h>".}

const
  cmdlinePath = "/proc/cmdline"
  loadOrderPath = "/etc/kickoff/modules"
  layoutPath = "/etc/kickoff/rootfstype"
  lowerDir = "/lower"          ## where the real root is mounted
  overlayDir = "/overlay"      ## tmpfs holding the writable upper layer
  mergedDir = "/sysroot"       ## overlay result, becomes /
  isoDir = "/isoroot"          ## where an ISO is mounted for the squashfs case
  defaultInit = "/sbin/init"
  deviceWaitMs = 10000

proc say(message: string) =
  ## Write straight to fd 1 and 2: no logging framework, and stdout may be the
  ## only thing attached.
  discard posix.write(1, message.cstring, message.len)
  discard posix.write(1, "\n".cstring, 1)

proc die(message: string) {.noreturn.} =
  say("kickoff-init: fatal: " & message)
  discard posix.write(2, message.cstring, message.len)
  discard posix.write(2, "\n".cstring, 1)
  # Sleep instead of exiting: exiting PID 1 panics the kernel.
  while true: discard posix.sleep(3600)

proc ensureDir(path: string) =
  if not dirExists(path):
    try: createDir(path)
    except OSError: discard

proc mountOrDie(source, target, fstype: string, flags: culong = 0,
                data: string = "") =
  let rc = mountFs(source, target, fstype, flags, data)
  if rc != 0:
    die("mount " & source & " -> " & target & " (" & fstype & "): " &
        mountErrorStr(rc))

proc readCmdline(): Table[string, string] =
  ## Parse /proc/cmdline into key=value pairs. Bare words (e.g. "rw") map to
  ## themselves with an empty value so callers can test with `hasKey`.
  var content = ""
  try:
    content = readFile(cmdlinePath)
  except IOError:
    return
  for token in content.splitWhitespace():
    let eq = token.find('=')
    if eq < 0:
      result[token] = ""
    else:
      result[token[0 ..< eq]] = token[eq + 1 .. ^1]

proc readTrimmed(path: string): string =
  try: readFile(path).strip()
  except IOError: ""

proc findPartitionByLabel(label: string): string =
  ## Locate a GPT partition by PARTLABEL without udev. /dev/disk/by-partlabel is
  ## created by udev, which an initramfs does not run, so read the name straight
  ## from sysfs instead.
  for kind, entry in walkDir("/sys/class/block"):
    let uevent = entry / "uevent"
    if not fileExists(uevent): continue
    var name = ""
    var partName = ""
    try:
      for line in lines(uevent):
        if line.startsWith("DEVNAME="): name = line[8 .. ^1]
        elif line.startsWith("PARTNAME="): partName = line[9 .. ^1]
    except IOError:
      continue
    if name.len > 0 and partName == label:
      return "/dev/" & name
  ""

proc waitForDevice(path: string, timeoutMs = deviceWaitMs): bool =
  var waited = 0
  while waited < timeoutMs:
    if fileExists(path): return true
    discard posix.usleep(100_000)
    waited += 100
  fileExists(path)

proc loadModules() =
  ## Load every module listed in the build-time order. Dependencies come first,
  ## so a failure means the archive itself is wrong.
  if not fileExists(loadOrderPath): return
  for rawLine in lines(loadOrderPath):
    let line = rawLine.strip()
    if line.len == 0: continue
    let path = "/modules/" & line
    if not fileExists(path):
      say("kickoff-init: warning: module listed but absent: " & path)
      continue
    let fd = posix.open(path.cstring, O_RDONLY)
    if fd < 0:
      say("kickoff-init: warning: cannot open " & path)
      continue
    # finit_module(2): syscall 273 on aarch64 and x86_64 alike for the 64-bit
    # ABI; loading by path avoids needing a module tree the kernel can search.
    if syscall(273, fd.cint, "".cstring, 0.cint) != 0:
      say("kickoff-init: warning: finit_module failed for " & path)
    discard posix.close(fd)

proc setupLoopDevice(filePath: string): string =
  ## Attach `filePath` to a free loop device and return its path. Done with
  ## ioctls because there is no losetup in the archive.
  const
    LOOP_SET_FD = 0x4C00'u64
    LOOP_CLR_FD = 0x4C01'u64
  let fd = posix.open(filePath.cstring, O_RDONLY)
  if fd < 0: die("cannot open squashfs image: " & filePath)
  for i in 0 ..< 8:
    let loop = "/dev/loop" & $i
    if not fileExists(loop): continue
    let lfd = posix.open(loop.cstring, O_RDWR)
    if lfd < 0: continue
    if ioctl(lfd, LOOP_SET_FD, fd) == 0:
      discard posix.close(lfd)
      return loop
    discard posix.close(lfd)
  discard posix.close(fd)
  die("no free loop device for " & filePath)

proc readLayout(): string =
  ## The build-time layout. "squashfs-iso" means the device holds an ISO with a
  ## squashfs image inside it rather than a squashfs filesystem directly.
  let value = readTrimmed(layoutPath)
  if value.len > 0: return value
  "erofs"

proc switchRoot(newRoot, initPath: string) {.noreturn.} =
  ## chdir into the new root, move it onto /, chroot, then exec the init.
  if chdir(newRoot.cstring) != 0: die("chdir " & newRoot)
  let rc = mountFs(".", "/", "", MS_MOVE, "")
  if rc != 0: die("mount --move " & newRoot & " -> /: " & mountErrorStr(rc))
  if chroot(".".cstring) != 0: die("chroot")
  if chdir("/".cstring) != 0: die("chdir /")
  say("kickoff-init: switching to " & initPath)
  let argv = allocCStringArray([initPath])
  discard execv(initPath.cstring, argv)
  die("exec " & initPath & " failed")

proc main() {.used.} =
  say("kickoff-init: starting")

  # API filesystems first: /proc/cmdline and the module loader both need them.
  ensureDir("/dev"); ensureDir("/proc"); ensureDir("/sys"); ensureDir("/run")
  discard mountFs("devtmpfs", "/dev", "devtmpfs", 0, "mode=0755")
  discard mountFs("none", "/proc", "proc", 0, "")
  discard mountFs("sysfs", "/sys", "sysfs", 0, "")
  discard mountFs("none", "/run", "tmpfs", 0, "mode=0755")
  ensureDir("/dev/pts")
  discard mountFs("devpts", "/dev/pts", "devpts", 0, "mode=0620")

  loadModules()

  let cmdline = readCmdline()
  let layout = readLayout()

  # root= is either PARTLABEL=NAME or an explicit device path.
  var device = ""
  if cmdline.hasKey("root"):
    let spec = cmdline["root"]
    if spec.startsWith("PARTLABEL="):
      let label = spec[11 .. ^1]
      device = findPartitionByLabel(label)
      if device.len == 0:
        die("no partition labelled " & label & " (is the disk module loaded?)")
    else:
      device = spec
  else:
    die("no root= on the kernel command line")

  if not waitForDevice(device):
    die("root device did not appear: " & device)
  say("kickoff-init: root device " & device & " (" & layout & ")")

  ensureDir(lowerDir)
  case layout
  of "squashfs-iso":
    # Device holds an ISO; the root is a squashfs image inside it.
    ensureDir(isoDir)
    mountOrDie(device, isoDir, "iso9660", MS_RDONLY)
    let image = isoDir / "LiveOS/rootfs.squashfs"
    let alt = isoDir / "LiveOS/squashfs.img"
    let source = if fileExists(image): image else: alt
    if not fileExists(source):
      die("no squashfs image under " & isoDir & "/LiveOS")
    let loop = setupLoopDevice(source)
    mountOrDie(loop, lowerDir, "squashfs", MS_RDONLY)
  of "squashfs":
    mountOrDie(device, lowerDir, "squashfs", MS_RDONLY)
  else:
    mountOrDie(device, lowerDir, "erofs", MS_RDONLY)

  # Overlay: the root is read-only, so a tmpfs upper layer makes the running
  # system writable. Disable with kickoff.overlay=0.
  let overlayEnabled = cmdline.getOrDefault("kickoff.overlay", "1") != "0"
  var targetRoot = lowerDir
  if overlayEnabled:
    ensureDir(overlayDir)
    discard mountFs("none", overlayDir, "tmpfs", 0, "mode=0755")
    ensureDir(overlayDir / "upper")
    ensureDir(overlayDir / "work")
    ensureDir(mergedDir)
    let data = "lowerdir=" & lowerDir & ",upperdir=" & overlayDir &
               "/upper,workdir=" & overlayDir & "/work"
    mountOrDie("overlay", mergedDir, "overlay", 0, data)
    targetRoot = mergedDir
    say("kickoff-init: overlay enabled (writable root)")

  # The init to run comes from the command line, never from this binary.
  var initPath = cmdline.getOrDefault("init", defaultInit)
  if initPath.len == 0: initPath = defaultInit
  if initPath[0] != '/':
    die("init= must be an absolute path: " & initPath)
  let resolved = targetRoot & initPath
  if not fileExists(resolved):
    die("init not found in the root filesystem: " & initPath)

  switchRoot(targetRoot, initPath)

when isMainModule:
  when defined(linux):
    main()
  else:
    echo "kickoff-init only runs on Linux"
