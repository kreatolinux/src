## Live ISO command. All assembly runs in a private workspace without mounts.
import std/[os, strutils]
import ../modules/[resources, isobuilder, isoprocess, erofsimage, bootconfig]
import ../../common/logging

proc runIso*(rootfs: string, output: string, init = "/sbin/init",
             dataDir = "", grubConfig = "", kernelVersion = "",
                 kernelImage = "",
             initramfs = "", workDir = "", imageSizeMiB = 0,
             clearRootPassword = false, name = "", overwrite = false,
             initramfsGenerator = "dracut") =
  ## Build a live ISO from a rootfs directory or tarball, without modifying the host.
  validateIsoGenerator(initramfsGenerator)
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
      name: name, overwrite: overwrite,
      initramfsGenerator: parseGenerator(initramfsGenerator))
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

proc runDisk*(rootfs: string, output: string, init = "/sbin/init",
              kernelVersion = "", kernelImage = "", initramfs = "",
              workDir = "", clearRootPassword = false, name = "",
              overwrite = false, initramfsGenerator = "dracut",
              partLabel = defaultPartLabel, writableMounts = true,
              bootloader = "none", arch = "", espSizeMiB = 0, console = "",
              kernelArgs = "") =
  ## Build a GPT disk image with a read-only EROFS root partition. With
  ## bootloader=grub it is also a UEFI-bootable ESP + root image.
  let options = ErofsOptions(rootfs: absolutePath(rootfs),
      output: absolutePath(output), init: init, kernelVersion: kernelVersion,
      kernelImage: kernelImage,
      initramfs: (if initramfs.len > 0: absolutePath(initramfs) else: ""),
      workDir: (if workDir.len > 0: absolutePath(workDir) else: ""),
      partLabel: partLabel, generator: parseGenerator(initramfsGenerator),
      writableMounts: writableMounts, clearRootPassword: clearRootPassword,
      name: name, overwrite: overwrite, bootloader: parseBootLoader(bootloader),
      arch: arch, espSizeMiB: espSizeMiB, console: console,
      kernelArgs: kernelArgs, verifyGrubDir: true)
  validateErofsOptions(options)
  if hostOS != "linux":
    raise newException(OSError, "Disk image assembly requires Linux; help and unit tests work on other hosts")
  if not isAdmin():
    raise newException(OSError, "Disk image assembly requires root to preserve rootfs ownership and device nodes")
  var missing: seq[string]
  for tool in requiredErofsTools(options):
    if findExe(tool).len == 0: missing.add(tool)
  if missing.len > 0:
    raise newException(OSError, "Missing disk image build tools: " &
        missing.join(", ") & ". Install them before building; krep will not " &
        "install host packages. Use --initramfs to skip initramfs generation" &
        (if options.bootloader == blGrub: " (--bootloader=grub also needs " &
        "dosfstools, mtools and GRUB EFI platform files)." else: "."))
  if clearRootPassword:
    warn "Explicitly clearing the staged root password. Do not use this image as a secure installed system."
  beginCancellation()
  defer: endCancellation()
  let image = assembleErofsImage(options, proc(exe: string, args: seq[string]) =
    info "Running " & exe
    checkedRun(exe, args), checkCancellation)
  ok "Created " & image
