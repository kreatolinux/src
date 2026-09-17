## Live ISO command. All assembly runs in a private workspace without mounts.
import std/[os, strutils]
import ../modules/[resources, isobuilder, isoprocess]
import ../../common/logging

proc runIso*(rootfs: string, output: string, init = "/sbin/init",
             dataDir = "", grubConfig = "", kernelVersion = "",
                 kernelImage = "",
             initramfs = "", workDir = "", imageSizeMiB = 0,
             clearRootPassword = false, name = "", overwrite = false) =
  ## Build a live ISO from a rootfs directory or tarball, without modifying the host.
  if hostOS != "linux":
    raise newException(OSError, "ISO assembly requires Linux; help and unit tests work on other hosts")
  if not isAdmin():
    raise newException(OSError, "ISO assembly requires root to preserve rootfs ownership and device nodes")
  let options = IsoOptions(rootfs: absolutePath(rootfs), output: absolutePath(
      output), resources: resolveResourceDir("iso", dataDir), init: init,
      grubConfig: (if grubConfig.len > 0: absolutePath(grubConfig) else: ""),
      kernelVersion: kernelVersion, kernelImage: kernelImage,
      initramfs: (if initramfs.len > 0: absolutePath(initramfs) else: ""),
      workDir: (if workDir.len > 0: absolutePath(workDir) else: ""),
      imageSizeMiB: imageSizeMiB, clearRootPassword: clearRootPassword,
      name: name, overwrite: overwrite)
  validateIsoOptions(options)
  var missing: seq[string]
  for tool in requiredIsoTools(options):
    if findExe(tool).len == 0: missing.add(tool)
  if missing.len > 0:
    let missingNames = missing.join(", ")
    let guidance = ". Install them before building; krep will not install host packages. "
    let alternative = "Use --initramfs to supply a compatible live initramfs instead of dracut."
    raise newException(OSError, "Missing ISO build tools: " & missingNames &
        guidance & alternative)
  if clearRootPassword:
    warn "Explicitly clearing the staged root password. Do not use this image as a secure installed system."
  beginCancellation()
  defer: endCancellation()
  let iso = assembleIso(options, proc(exe: string, args: seq[string]) =
    info "Running " & exe
    checkedRun(exe, args), checkCancellation)
  ok "Created " & iso
