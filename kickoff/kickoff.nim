## kickoff — build an initramfs for a Kreato rootfs.
##
## One CLI, same shape as krep: cligen's dispatchMulti with the command
## implementations in commands/.

import cligen

import commands/[buildcmd, versioncmd]
import ../common/version

when isMainModule:
  clCfg.version = "kickoff " & ver & ", commit " & commitVer

  try:
    dispatchMulti(
      # "multi" is the generated dispatcher's name; cmdName is what users see.
      # Passing anything else as the string prefix leaves the generated proc
      # named after it while cligen still refers to `multi`.
      ["multi", cmdName = "kickoff",
        doc = "Build an initramfs for a Kreato rootfs.\n\n"],
      [build, help = {
        "rootfs": "Staged rootfs to take kernel modules and libraries from",
        "init": "The initramfs init binary; it runs as PID 1",
        "kernelVersion": "Kernel version, selects /lib/modules/VERSION",
        "output": "Archive to write",
        "layout": "Root filesystem: erofs (default), squashfs, or squashfs-iso",
        "compress": "Compression: gzip (default), zstd, or none",
        "module": "Extra kernel module to include (repeatable)",
        "mtime": "Archive timestamp; default is SOURCE_DATE_EPOCH, else 0"}],
      [versionCommand, cmdName = "version"])
  except CatchableError as exc:
    stderr.writeLine("kickoff: error: " & exc.msg)
    quit(1)
