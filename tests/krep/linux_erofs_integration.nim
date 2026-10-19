## Opt-in Linux driver for the EROFS disk image pipeline (see tests/krep/docker/).
## linux_erofs_integration ROOTFS OUTPUT INIT GENERATOR [PARTLABEL]
## Optional env: KREP_BOOTLOADER=grub (+ KREP_CONSOLE, KREP_KERNEL_ARGS,
## KREP_ESP_MIB, KREP_ARCH) builds the UEFI-bootable layout;
## KREP_NO_WRITABLE=1 keeps the rootfs /etc/fstab as is.
import std/[os, strutils]
import ../../krep/modules/[erofsimage, isoprocess]

if paramCount() notin 4..5:
  quit("usage: linux_erofs_integration ROOTFS OUTPUT INIT dracut|booster [PARTLABEL]", 2)
let options = ErofsOptions(rootfs: absolutePath(paramStr(1)),
    output: absolutePath(paramStr(2)), init: paramStr(3),
    generator: parseGenerator(paramStr(4)),
    partLabel: (if paramCount() == 5: paramStr(5) else: defaultPartLabel),
    name: "integration.img", writableMounts: getEnv("KREP_NO_WRITABLE").len == 0,
    overwrite: true, bootloader: parseBootLoader(getEnv("KREP_BOOTLOADER")),
    arch: getEnv("KREP_ARCH"), console: getEnv("KREP_CONSOLE"),
    kernelArgs: getEnv("KREP_KERNEL_ARGS"),
    espSizeMiB: (if getEnv("KREP_ESP_MIB").len > 0: parseInt(getEnv("KREP_ESP_MIB")) else: 0),
    verifyGrubDir: true)
proc runner(exe: string, args: seq[string]) =
  echo "RUN ", exe, " ", args.join(" ")
  checkedRun(exe, args)
withCancellation:
  echo "OUTPUT ", assembleErofsImage(options, runner, checkCancellation)
