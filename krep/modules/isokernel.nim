## Select ISO boot assets from the target rootfs, never the build host.
import std/[algorithm, os, strutils]
import ./bootconfig

type KernelSelection* = object
  version*: string
  image*: string
  modulesDir*: string

proc validateVersion(version: string) =
  if version.len == 0 or version in [".", ".."] or version[0] == '-':
    raise newException(ValueError, "Invalid kernel version: " & version)
  for ch in version:
    if ch notin {'a'..'z', 'A'..'Z', '0'..'9', '.', '_', '-', '+'}:
      raise newException(ValueError, "Invalid kernel version: " & version)

proc validateImagePath(path: string) =
  if not path.isAbsolute or path == "/":
    raise newException(ValueError,
      "Kernel image must be an absolute path inside the rootfs")
  for part in path.split('/'):
    if part == "..":
      raise newException(ValueError, "Kernel image path must not contain '..'")
  for ch in path:
    if ch in {'\0', '\n', '\r'}:
      raise newException(ValueError, "Invalid kernel image path")

proc validateModuleLinks(modulesDir: string) =
  ## dracut/kmod read this tree on the host, not in a chroot. Root-relative
  ## absolute links are therefore unsafe here even when selection resolves them.
  ## Kernel development links are not boot assets and are not consumed by kmod.
  proc unsafeLink(path: string, reason: string): ref ValueError =
    newException(ValueError, "Unsafe module symlink (" & reason & "): " & path &
      "; normalize boot-asset links to relative paths inside the selected module tree")

  proc resolveLink(path: string): string =
    var pending = relativePath(path, modulesDir).split('/')
    var parts: seq[string]
    var links = 0
    while pending.len > 0:
      let part = pending[0]
      pending.delete(0)
      case part
      of "", ".": continue
      of "..":
        if parts.len == 0:
          raise unsafeLink(path, "escapes selected tree")
        parts.setLen(parts.len - 1)
      else:
        let candidate = modulesDir / parts.join("/") / part
        if symlinkExists(candidate):
          inc links
          let target = expandSymlink(candidate)
          if links > 40 or target.isAbsolute or
              (parts.len == 0 and part in ["build", "source"]):
            raise unsafeLink(candidate, "absolute, cyclic, or development link")
          pending = target.split('/') & pending
        else:
          parts.add(part)
    result = modulesDir / parts.join("/")
    if not fileExists(result) and not dirExists(result):
      raise unsafeLink(path, "missing target")

  proc scan(directory: string) =
    for kind, path in walkDir(directory):
      if symlinkExists(path):
        if directory == modulesDir and path.extractFilename in ["build", "source"]:
          continue
        discard resolveLink(path)
      elif kind == pcDir:
        scan(path)
  scan(modulesDir)

proc selectKernel*(rootfs: string, kernelVersion = "",
                   kernelImage = ""): KernelSelection =
  ## Returned image and modulesDir are resolved filesystem paths under rootfs.
  ## kernelImage, when set, is a root-relative absolute path, e.g. /boot/custom.
  ## An explicit image asserts its association with the selected module version.
  ## Generic image names are used only when exactly one module version exists.
  ## modules.dep is required: dracut needs an indexed target module tree.
  if rootfs.len == 0 or not dirExists(rootfs):
    raise newException(ValueError, "Kernel rootfs directory does not exist: " & rootfs)
  if kernelVersion.len > 0: validateVersion(kernelVersion)
  if kernelImage.len > 0: validateImagePath(kernelImage)

  let root = absolutePath(rootfs)
  var versions: seq[string]
  var modulePaths: seq[string]
  for modulesBase in ["/usr/lib/modules", "/lib/modules"]:
    let resolvedBase = resolveRootfsPath(root, modulesBase)
    if not dirExists(resolvedBase): continue
    for kind, entry in walkDir(resolvedBase):
      let version = entry.extractFilename
      let resolved = resolveRootfsPath(root, modulesBase / version)
      if not dirExists(resolved): continue
      validateVersion(version)
      let existing = versions.find(version)
      if existing >= 0:
        if modulePaths[existing] != resolved:
          raise newException(ValueError,
            "Conflicting module trees for kernel " & version)
      else:
        versions.add(version)
        modulePaths.add(resolved)

  if versions.len == 0:
    raise newException(ValueError, "No kernel modules found inside rootfs")
  if kernelVersion.len == 0:
    if versions.len != 1:
      var available = versions
      available.sort()
      raise newException(ValueError,
        "Multiple kernel versions in rootfs; select one explicitly: " &
        available.join(", "))
    result.version = versions[0]
  else:
    if kernelVersion notin versions:
      raise newException(ValueError,
        "No rootfs modules for kernel " & kernelVersion)
    result.version = kernelVersion
  result.modulesDir = modulePaths[versions.find(result.version)]
  # dracut derives the target module location from this exact path layout.
  # Resolving a version-directory link elsewhere is safe for our own reads,
  # but cannot be passed to dracut as an arbitrary --kmoddir directory.
  if not result.modulesDir.endsWith("/lib/modules/" & result.version):
    raise newException(ValueError,
      "Resolved kernel modules must be under /lib/modules/" & result.version &
      " (or /usr/lib/modules/" & result.version & ") for dracut: " &
      result.modulesDir)
  validateModuleLinks(result.modulesDir)
  let relativeModules = relativePath(result.modulesDir, root)
  let dep = resolveRootfsPath(root, "/" & relativeModules & "/modules.dep")
  if not fileExists(dep):
    raise newException(ValueError,
      "Missing modules.dep for rootfs kernel " & result.version & "; run depmod for the target")

  if kernelImage.len > 0:
    result.image = resolveRootfsPath(root, kernelImage)
    if not fileExists(result.image):
      raise newException(ValueError, "Kernel image does not exist inside rootfs: " & kernelImage)
    return

  var candidates = @["/boot/vmlinuz-" & result.version,
                     "/boot/Image-" & result.version]
  if versions.len == 1:
    candidates.add("/boot/vmlinuz")
    candidates.add("/boot/Image")
  for candidate in candidates:
    let resolved = resolveRootfsPath(root, candidate)
    if fileExists(resolved):
      result.image = resolved
      return
  raise newException(ValueError,
    "No matching kernel image inside rootfs for " & result.version &
    "; install /boot/vmlinuz-VERSION or /boot/Image-VERSION, or set kernelImage")
