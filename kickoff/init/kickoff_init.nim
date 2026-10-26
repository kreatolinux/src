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
import ../modules/iso9660

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
  isoLabelPath = "/etc/kickoff/isolabel"
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

proc exists(path: string): bool =
  ## True for any object, including block and character devices.
  ##
  ## Nim's fileExists() is documented as "exists and is a regular file or
  ## symlink. Directories, device files, named pipes and sockets return false",
  ## which makes it the wrong test for /dev/vda and friends. This init checks for
  ## device nodes in several places, and using fileExists() there silently
  ## reported every block device as absent.
  var st: Stat
  posix.stat(path.cstring, st) == 0

proc readSector(device: string, sectorIndex: int): string =
  ## Read one 2048-byte sector without seeking the shared file offset (pread),
  ## so this can be called for several devices without reopening.
  result = newString(sectorSize)
  let fd = posix.open(device.cstring, O_RDONLY)
  if fd < 0: return ""
  try:
    let n = posix.pread(fd, addr result[0], sectorSize, posix.Off(sectorIndex * sectorSize))
    if n != sectorSize: result = ""
  finally:
    discard posix.close(fd)

proc findIsoDevice(label: string): string =
  ## Find a block device carrying an ISO9660 filesystem. With `label` non-empty
  ## only a matching volume identifier is accepted; otherwise the first ISO9660
  ## device wins, which is what a live medium wants.
  ##
  ## The whole device and its partitions are both candidates: an ISO written to a
  ## USB stick may appear either way depending on how it was partitioned.
  for kind, entry in walkDir("/sys/class/block"):
    let devName = "/dev/" & entry.extractFilename()
    if not exists(devName): continue
    let pvd = readSector(devName, pvdSector)
    if pvd.len == 0: continue
    let found = isoVolumeId(pvd)
    if found.len == 0: continue
    if label.len == 0 or found == label:
      return devName
  ""

proc resolveRootDevice(spec, layout, isoLabelOverride: string): string =
  ## Turn the kernel's root= value into a device node.
  ##
  ## Supported forms:
  ##   PARTLABEL=name   GPT partition label, read from sysfs
  ##   LABEL=name       ISO9660 volume identifier (no udev, so read from the PVD)
  ##   CDLABEL=name     as LABEL, for familiarity with dracut's live syntax
  ##   live:LABEL=name  dracut's live-media form, accepted for compatibility
  ##   /dev/...         taken as-is
  ## An empty spec on a squashfs-iso layout means "the live medium": any ISO9660
  ## device will do.
  if spec.len == 0:
    if layout == "squashfs-iso": return findIsoDevice(isoLabelOverride)
    return ""
  var value = spec
  if value.startsWith("live:"): value = value[5 .. ^1]
  if value.startsWith("PARTLABEL="):
    return findPartitionByLabel(value[11 .. ^1])
  for prefix in ["CDLABEL=", "LABEL="]:
    if value.startsWith(prefix):
      let label = value[prefix.len .. ^1]
      return findIsoDevice(label)
  return value

proc waitForDevice(path: string, timeoutMs = deviceWaitMs): bool =
  var waited = 0
  while waited < timeoutMs:
    if exists(path): return true
    discard posix.usleep(100_000)
    waited += 100
  exists(path)

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

proc loopControlDevice(): string =
  ## Ask the loop driver for a free device.
  ##
  ## Since Linux 5.x the driver creates devices on demand and the module's
  ## max_loop default is 0, so /dev/loop0..N do not exist until somebody asks
  ## for one. Scanning for a node that already exists therefore finds nothing on
  ## a modern kernel, which is exactly what the first live boot hit.
  const LOOP_CTL_GET_FREE = 0x4C82'u64
  let ctl = posix.open("/dev/loop-control".cstring, O_RDWR)
  if ctl < 0: return ""
  try:
    let index = ioctl(ctl, LOOP_CTL_GET_FREE, 0)
    if index < 0: return ""
    let device = "/dev/loop" & $index
    # devtmpfs creates the node, but not necessarily before we look.
    for _ in 0 ..< 50:
      if exists(device): return device
      discard posix.usleep(100_000)
    ""
  finally:
    discard posix.close(ctl)

proc setupLoopDevice(filePath: string): string =
  ## Attach `filePath` to a loop device and return its path. Done with ioctls
  ## because there is no losetup in the archive.
  const LOOP_SET_FD = 0x4C00'u64
  let fd = posix.open(filePath.cstring, O_RDONLY)
  if fd < 0: die("cannot open squashfs image: " & filePath)
  var candidates: seq[string] = @[]
  let allocated = loopControlDevice()
  if allocated.len > 0: candidates.add allocated
  # Keep the scan as a fallback for kernels that pre-create the nodes.
  for i in 0 ..< 16:
    let loop = "/dev/loop" & $i
    if exists(loop) and loop notin candidates: candidates.add loop
  for loop in candidates:
    let lfd = posix.open(loop.cstring, O_RDWR)
    if lfd < 0: continue
    if ioctl(lfd, LOOP_SET_FD, fd) == 0:
      discard posix.close(lfd)
      discard posix.close(fd)
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
  # Now that / is the new root, an absolute symlink resolves inside it.
  if not exists(initPath):
    die("init not found in the root filesystem: " & initPath)
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

  # Resolve root= to a device. Retry until the timeout: a device can appear
  # slightly after the module that drives it has been loaded.
  let rootSpec = cmdline.getOrDefault("root", "")
  # Command line wins; otherwise fall back to the label baked in at build time.
  var isoLabelOverride = cmdline.getOrDefault("kickoff.isolabel", "")
  if isoLabelOverride.len == 0:
    isoLabelOverride = readTrimmed(isoLabelPath)
  var device = ""
  var waited = 0
  while waited < deviceWaitMs:
    device = resolveRootDevice(rootSpec, layout, isoLabelOverride)
    if device.len > 0 and exists(device): break
    discard posix.usleep(200_000)
    waited += 200
  if device.len == 0 or not exists(device):
    die("could not find a root device for root='" & rootSpec &
        "' (layout " & layout & ", modules loaded?)")
  say("kickoff-init: root device " & device & " (" & layout & ")")

  ensureDir(lowerDir)
  case layout
  of "squashfs-iso":
    # The device holds an ISO9660 image; the root is a squashfs file inside it.
    # kickoff's ISO layout puts the rootfs at LiveOS/rootfs.squashfs directly.
    # It deliberately does not support a squashfs-wrapped ext4 rootfs.img: that
    # needs a second mount and dm-snapshot, which is the dracut path's job, and
    # silently mounting the wrong layer would be worse than failing.
    ensureDir(isoDir)
    mountOrDie(device, isoDir, "iso9660", MS_RDONLY)
    let source = isoDir / "LiveOS/rootfs.squashfs"
    if not fileExists(source):
      die("no LiveOS/rootfs.squashfs on " & device &
          " (is this an ISO built with --initramfsGenerator=kickoff?)")
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
  # Do not check for initPath here: it is usually a symlink whose target is
  # absolute (/sbin/init -> /bin/jumpstart), so resolving it from outside the
  # new root looks it up in the initramfs and fails. switchRoot checks it after
  # chroot, where the links mean what they were built to mean.
  switchRoot(targetRoot, initPath)

when isMainModule:
  when defined(linux):
    main()
  else:
    echo "kickoff-init only runs on Linux"
