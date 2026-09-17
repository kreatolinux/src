## Opt-in Linux ISO integration driver. Not part of the mock unit suite.
## Requires a trusted rootfs with matching boot/vmlinuz-<version> and
## lib/modules/<version>, plus the ISO host tools documented in krep/ISO.md.
## nim c -r tests/krep/linux_iso_integration.nim ROOTFS RESOURCES OUTPUT [GRUB_CONFIG]
import std/[os, strutils]
import ../../krep/modules/isobuilder
import ../../krep/modules/isoprocess

if paramCount() notin 3..4:
  quit("usage: linux_iso_integration ROOTFS RESOURCES OUTPUT [GRUB_CONFIG]", 2)
let output = absolutePath(paramStr(3))
let options = IsoOptions(rootfs: absolutePath(paramStr(1)),
    resources: absolutePath(paramStr(2)), output: output,
    init: "/sbin/init", name: "integration.iso",
    grubConfig: (if paramCount() == 4: absolutePath(paramStr(4)) else: ""))
proc runner(exe: string, args: seq[string]) =
  echo "RUN ", exe, " ", args.join(" ")
  checkedRun(exe, args)
withCancellation:
  echo "OUTPUT ", assembleIso(options, runner, checkCancellation)
