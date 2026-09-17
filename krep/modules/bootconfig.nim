## Init-independent live boot configuration. No kpkg or CLI initialization here.
import std/[os, strutils]

proc validateInitPath*(init: string) =
  ## Keep the path safe for a single kernel command-line argument.
  if init.len < 2 or init[0] != '/':
    raise newException(ValueError, "Init must be an absolute path inside the rootfs")
  for ch in init:
    if ch notin {'a'..'z', 'A'..'Z', '0'..'9', '/', '.', '_', '-', '+'}:
      raise newException(ValueError, "Invalid character in init path")
  for part in init.split('/'):
    if part == "..":
      raise newException(ValueError, "Init path must not contain '..'")

proc resolveRootfsPath*(rootfs, path: string): string =
  ## Resolve symlinks with chroot semantics, including absolute /sbin/init links
  ## and usr-merged /sbin directories. Never resolve against the host root.
  var pending = path.split('/')
  var parts: seq[string]
  var links = 0
  while pending.len > 0:
    let part = pending[0]
    pending.delete(0)
    case part
    of "", ".": continue
    of "..":
      if parts.len > 0: parts.setLen(parts.len - 1)
    else:
      let candidate = rootfs / parts.join("/") / part
      if symlinkExists(candidate):
        inc links
        if links > 40:
          raise newException(ValueError, "Too many symlinks in rootfs path: " & path)
        let target = expandSymlink(candidate)
        if target.isAbsolute: parts.setLen(0)
        pending = target.split('/') & pending
      else:
        parts.add(part)
  result = rootfs / parts.join("/")

proc validateRootfsInit*(rootfs, init: string) =
  validateInitPath(init)
  let resolved = resolveRootfsPath(rootfs, init)
  if not fileExists(resolved):
    raise newException(ValueError, "Rootfs init does not exist: " & init)
  if (getFilePermissions(resolved) * {fpUserExec, fpGroupExec, fpOthersExec}) == {}:
    raise newException(ValueError, "Rootfs init is not executable: " & init)

proc initOverlayPath*(dataDir, initSystem: string): string =
  ## Metadata selects optional customizations, not which init systems may boot.
  if initSystem.len == 0 or initSystem in [".", ".."]: return ""
  for ch in initSystem:
    if ch notin {'a'..'z', 'A'..'Z', '0'..'9', '_', '-'}: return ""
  result = dataDir / "overlays" / initSystem

proc copyRootfsOverlay(source, rootfs: string, relative = "") =
  ## Resolve destination directories with chroot semantics. In particular, an
  ## absolute /etc symlink in the image must never direct writes into host /etc.
  let destinationDir = resolveRootfsPath(rootfs, relative)
  createDir(destinationDir)
  for kind, sourcePath in walkDir(source):
    let child = relative / sourcePath.extractFilename
    if kind == pcDir:
      copyRootfsOverlay(sourcePath, rootfs, child)
    else:
      # Resolve the parent, not the final entry: replacing an existing symlink
      # must replace the link itself, rather than writing through its target.
      let destination = resolveRootfsPath(rootfs, child.parentDir) /
          child.extractFilename
      if symlinkExists(destination) or fileExists(destination):
        removeFile(destination)
      case kind
      of pcLinkToFile, pcLinkToDir:
        createSymlink(expandSymlink(sourcePath), destination)
      of pcFile:
        copyFileWithPermissions(sourcePath, destination,
            ignorePermissionErrors = false)
      of pcDir: discard
  setFilePermissions(destinationDir, getFilePermissions(source))

proc prepareLiveRootfs*(rootfs, dataDir, initSystem, init: string) =
  ## Bundled overlays do not change passwords, getty settings, or firstboot.
  ## A user-supplied overlay can intentionally customize those settings.
  let sharedOverlay = dataDir / "overlay"
  if dirExists(sharedOverlay):
    copyRootfsOverlay(sharedOverlay, rootfs)
  let specificOverlay = initOverlayPath(dataDir, initSystem)
  if specificOverlay != "" and dirExists(specificOverlay):
    copyRootfsOverlay(specificOverlay, rootfs)
  validateRootfsInit(rootfs, init)

proc liveDracutArgs*(kernelVersion, output: string, modulesDir = "",
                     kernelImage = "", configDir = ""): seq[string] =
  ## Use dracut's shell init, independently of the host and target init systems.
  ## Callers select the target kernel explicitly; never use the running kernel.
  if kernelVersion.len == 0 or output.len == 0:
    raise newException(ValueError, "Dracut requires a kernel version and output path")
  result = @["--force", "--no-hostonly", "--no-hostonly-cmdline",
    "--modules", "base dmsquash-live kernel-modules",
    "--force-drivers", "loop dm_snapshot overlay",
    "--filesystems", "ext4 squashfs iso9660",
    "--omit", "systemd systemd-initrd",
    "--kver", kernelVersion]
  if modulesDir.len > 0: result.add(@["--kmoddir", modulesDir])
  if kernelImage.len > 0: result.add(@["--kernel-image", kernelImage])
  if configDir.len > 0:
    result.add(@["--conf", "/dev/null", "--confdir", configDir])
  result.add(output)

proc liveGrubConfig*(templateText, init: string): string =
  validateInitPath(init)
  if "@INIT@" notin templateText:
    raise newException(ValueError, "GRUB template is missing @INIT@")
  result = templateText.replace("@INIT@", init)
