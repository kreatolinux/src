## `kickoff build` — assemble an initramfs from a staged rootfs.
##
## Kept out of the CLI entry point so the dispatch table stays declarative, the
## same way krep splits commands/.

import std/[os, strutils]

# `compress` and `module` are natural CLI flag names but collide with the module
# names below, so the modules are imported under aliases.
import ../modules/assemble
import ../modules/compress as compressionmod
import ../modules/cpio as cpiomod
import ../modules/modules as modulesmod

proc build*(rootfs: string, init: string, kernelVersion: string, output: string,
            layout = "erofs", compress = "gzip",
            module: seq[string] = @[], mtime = -1, isoLabel = ""): int =
  ## Build an initramfs for a staged rootfs.
  ##
  ## `rootfs` supplies the kernel modules and the shared libraries the init needs.
  ## `init` is the binary that becomes /init and runs as PID 1. `layout` decides
  ## which modules are required and how the init mounts the root at boot. `mtime`
  ## defaults to SOURCE_DATE_EPOCH, or 0 when that is unset, so two builds of the
  ## same tree produce identical archives.
  let resolvedMtime =
    if mtime >= 0: uint32(mtime)
    else: cpiomod.sourceDateEpoch()

  let options = InitramfsOptions(
    rootfs: rootfs,
    initBinary: init,
    kernelVersion: kernelVersion,
    layout: modulesmod.parseLayout(layout),
    compression: compressionmod.parseCompression(compress),
    extraModules: module,
    mtime: resolvedMtime,
    isoLabel: isoLabel)

  let result = writeInitramfs(options, output)

  echo "initramfs: ", output
  echo "  layout:      ", $options.layout
  echo "  compression: ", $options.compression, " (", getFileSize(output), " bytes)"
  echo "  modules:     ", result.modules.len
  for skipped in result.skippedBuiltin:
    echo "    built in, not copied: ", skipped
  echo "  libraries:   ", result.libraries.len
  for lib in result.libraries:
    echo "    ", lib
  echo "  entries:     ", result.entries.len
  0
