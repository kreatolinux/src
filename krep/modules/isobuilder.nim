## ISO assembly without mounts, loop devices, host package installs, or host kernels.
## The command runner is injected so failure cleanup is testable without root.
import std/[os, strutils, parsecfg, times]
import bootconfig, isokernel, isoworkspace

type
  IsoOptions* = object
    rootfs*, output*, resources*, grubConfig*: string
    init*: string
    kernelVersion*, kernelImage*, initramfs*, workDir*: string
    clearRootPassword*, overwrite*: bool
    imageSizeMiB*: int
    name*: string
  IsoRunner* = proc(exe: string, args: seq[string]) {.closure.}

proc requiredIsoTools*(options: IsoOptions): seq[string] =
  result = @["cp", "truncate", "mkfs.ext4", "mksquashfs", "grub-mkrescue", "xorriso"]
  if not dirExists(options.rootfs): result.add("tar")
  if options.initramfs.len == 0:
    result.add(@["dracut", "udevadm", "depmod", "modprobe", "dmsetup",
        "switch_root"])

proc canonicalFuturePath(path: string): string =
  ## Resolve existing parent aliases even when the final output does not exist.
  var existing = absolutePath(path)
  var tail: seq[string]
  while not dirExists(existing) and not fileExists(existing) and
      not symlinkExists(existing):
    tail.add(existing.extractFilename)
    let parent = existing.parentDir
    if parent == existing: break
    existing = parent
  result = expandFilename(existing)
  for i in countdown(tail.high, 0): result = result / tail[i]

proc validateIsoOptions*(options: IsoOptions) =
  if not dirExists(options.rootfs) and not fileExists(options.rootfs):
    raise newException(ValueError, "Rootfs directory or archive does not exist: " &
        options.rootfs)
  if options.initramfs.len > 0 and not fileExists(options.initramfs):
    raise newException(ValueError, "Initramfs does not exist: " &
        options.initramfs)
  validateInitPath(options.init)
  if dirExists(options.rootfs):
    let source = expandFilename(options.rootfs)
    let workParent = expandFilename(if options.workDir.len >
        0: options.workDir else: getTempDir())
    if workParent == source or workParent.startsWith(source & DirSep):
      raise newException(ValueError, "Workspace must be outside the input rootfs")
    let output = canonicalFuturePath(options.output)
    if output == source or output.startsWith(source & DirSep):
      raise newException(ValueError, "Output must be outside the input rootfs")
  if options.imageSizeMiB < 0:
    raise newException(ValueError, "imageSizeMiB must be zero (automatic) or positive")
  if options.name.len > 0:
    if options.name in [".", ".."] or options.name[0] == '.':
      raise newException(ValueError, "ISO name must be a visible filename")
    for ch in options.name:
      if ch notin {'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.', '+'}:
        raise newException(ValueError, "ISO name must be a filename, not a path")
    if not options.name.endsWith(".iso"):
      raise newException(ValueError, "ISO name must end in .iso")

proc fileSlug(value, fallback: string): string =
  for ch in value:
    if ch in {'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.', '+'}: result.add(ch)
    else: result.add('-')
  if result.len == 0: result = fallback

proc clearStagedRootPassword*(rootfs: string) =
  ## Never run passwd/chroot or follow an absolute rootfs link into the host.
  let path = resolveRootfsPath(rootfs, "/etc/shadow")
  if not fileExists(path):
    raise newException(ValueError, "--clearRootPassword requires /etc/shadow in the rootfs")
  var lines = readFile(path).splitLines()
  var found = false
  for line in lines.mitems:
    if line.startsWith("root:"):
      var fields = line.split(':')
      if fields.len != 9:
        raise newException(ValueError, "Invalid root entry in staged /etc/shadow")
      fields[1] = ""
      line = fields.join(":")
      found = true
  if not found: raise newException(ValueError, "No root entry in staged /etc/shadow")
  writeFile(path, lines.join("\n"))

proc rootfsImageSizeMiB*(rootfs: string): int64 =
  ## Count apparent bytes plus per-entry overhead. Never follow rootfs symlinks.
  var bytes = 0'i64
  var entries = 0'i64
  proc count(path: string) =
    for kind, child in walkDir(path):
      inc entries
      case kind
      of pcDir: count(child)
      of pcFile:
        # getFileInfo reports device nodes/FIFOs as pcFile too; size is zero.
        bytes += getFileInfo(child, followSymlink = false).size
      else: discard
  count(rootfs)
  let mib = 1024'i64 * 1024
  max(256'i64, (bytes + bytes div 4 + entries * 16384 + 128 * mib + mib - 1) div mib)

proc assembleIso*(options: IsoOptions, run: IsoRunner,
                  checkCancelled: proc() {.closure.} = nil): string =
  ## Raises on failure so workspace and output lock are released by defer.
  ## Input archives/directories and custom overlays must be trusted.
  validateIsoOptions(options)
  if checkCancelled != nil: checkCancelled()
  let templatePath = if options.grubConfig.len > 0: options.grubConfig
                     else: options.resources / "grub.cfg"
  let grubText = liveGrubConfig(readFile(templatePath), options.init)
  createDir(options.output)
  let workspace = createWorkspace(options.workDir)
  defer: cleanupWorkspace(workspace)
  let staged = workspace.path / "rootfs"
  let squash = workspace.path / "squashfs"
  let imageTree = workspace.path / "image"
  createDir(staged)
  createDir(squash / "LiveOS")
  createDir(imageTree / "LiveOS")
  createDir(imageTree / "boot/grub")

  if dirExists(options.rootfs):
    run("cp", @["-a", "--", options.rootfs & "/.", staged])
  else:
    run("tar", @["--extract", "--file", options.rootfs, "--directory", staged,
                  "--numeric-owner", "--same-owner", "--preserve-permissions",
                  "--xattrs", "--xattrs-include=*", "--acls"])

  if checkCancelled != nil: checkCancelled()
  var metadata = newConfig()
  let releasePath = resolveRootfsPath(staged, "/etc/kreato-release")
  if fileExists(releasePath): metadata = loadConfig(releasePath)
  prepareLiveRootfs(staged, options.resources,
      metadata.getSectionValue("Core", "init"), options.init)
  let kernel = selectKernel(staged, options.kernelVersion, options.kernelImage)
  let date = fileSlug(metadata.getSectionValue("General", "dateBuilt"),
      getDateStr())
  let version = fileSlug(metadata.getSectionValue("General", "klinuxVersion"), "live")
  let name = if options.name.len > 0: options.name
             else: "kreatolinux-" & date & "-" & version & "-" &
                 kernel.version & ".iso"
  result = options.output / name
  let outputLock = acquireOutputLock(result)
  defer: releaseOutputLock(outputLock)
  if (fileExists(result) or dirExists(result) or symlinkExists(result)) and
      not options.overwrite:
    raise newException(IOError, "Output already exists (use --overwrite): " & result)

  if checkCancelled != nil: checkCancelled()
  if options.clearRootPassword: clearStagedRootPassword(staged)
  # Stage only the selected rootfs kernel, never copy /boot from the host.
  copyFile(kernel.image, imageTree / "boot/vmlinuz")
  if options.initramfs.len > 0:
    copyFile(options.initramfs, imageTree / "boot/initramfs.img")
  else:
    let emptyConfig = workspace.path / "dracut.conf.d"
    createDir(emptyConfig)
    run("dracut", liveDracutArgs(kernel.version, imageTree /
        "boot/initramfs.img", kernel.modulesDir, kernel.image, emptyConfig))
  if not fileExists(imageTree / "boot/initramfs.img"):
    raise newException(IOError, "No initramfs was generated")

  let size = if options.imageSizeMiB > 0: int64(options.imageSizeMiB)
             else: rootfsImageSizeMiB(staged)
  let image = squash / "LiveOS/rootfs.img"
  run("truncate", @["--size", $size & "M", "--", image])
  # mke2fs -d populates the filesystem without mounting it. Disable lazy init
  # so data/metadata are complete before the image is compressed.
  run("mkfs.ext4", @["-F", "-q", "-m", "0", "-E",
      "lazy_itable_init=0,lazy_journal_init=0", "-d", staged, image])
  run("mksquashfs", @[squash, imageTree / "LiveOS/squashfs.img", "-noappend"])
  writeFile(imageTree / "boot/grub/grub.cfg", grubText)
  let stagedIso = workspace.path / "result.iso"
  run("grub-mkrescue", @["-o", stagedIso, imageTree, "-volid", "ISOIMAGE"])
  if not fileExists(stagedIso):
    raise newException(IOError, "grub-mkrescue did not produce an ISO")
  publishIso(stagedIso, outputLock, options.overwrite, checkCancelled)
