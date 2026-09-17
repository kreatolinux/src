## Image subcommands. The owning executable initializes logging and cligen.
import rootfscmd
import isocmd

proc rootfs*(buildType = "builder", arch = "amd64", useCacheIfPossible = true,
             noSandbox = false, dataDir = "", configPath = "",
                 overlayPath = "") =
  ## Build a Kreato Linux rootfs from the selected configuration.
  runRootfs(buildType, arch, useCacheIfPossible, noSandbox, dataDir,
            configPath, overlayPath)

proc iso*(rootfs: string, output: string, init = "/sbin/init", dataDir = "",
          grubConfig = "", kernelVersion = "", kernelImage = "", initramfs = "",
          workDir = "", imageSizeMiB = 0, clearRootPassword = false,
          name = "", overwrite = false) =
  ## Build a live ISO from a rootfs directory or archive, using its kernel.
  runIso(rootfs, output, init, dataDir, grubConfig, kernelVersion, kernelImage,
         initramfs, workDir, imageSizeMiB, clearRootPassword, name, overwrite)
