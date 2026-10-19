## Kreato Linux Repository Maintainer: one CLI, shared command implementations.
import cligen
import commands/[repository, runfiles, generation, images]
import ../common/[logging, version]

when isMainModule:
  initLogger("krep", "", "/var/log/krep.log")
  clCfg.version = "krep " & ver & ", commit " & commitVer

  dispatchMultiGen(["generators", cmdName = "krep generate",
      doc = "Generate a build matrix or documentation.\n\n"],
    [matrix], [markdown], [manpage])

  proc generate(cmdLine: seq[string]) =
    # dispatchMultiGen does not implement dispatchMulti's `help COMMAND`
    # normalization. Keep the advertised nested help syntax consistent.
    if cmdLine.len == 2 and cmdLine[0] == "help":
      generators(@[cmdLine[1], "--help"])
    else:
      generators(cmdLine)

  try:
    dispatchMulti(
      ["multi", cmdName = "krep",
        doc = "Kreato Linux Repository Maintainer.\n\n"],
      [check, help = {
        "package": "Package name or quoted wildcard pattern",
        "repo": "Repository directory",
        "backend": "Upstream backend (repology, arch, githubReleases)"}],
      [update, help = {
        "package": "Package name or quoted wildcard pattern",
        "repo": "Repository directory",
        "backend": "Upstream backend (repology, arch, githubReleases)"}],
      [clean], [lint], [fmt], [convert],
      [generate, doc = "Generate a build matrix or documentation",
        usage = "$doc\n\n  krep generate {matrix|markdown|manpage} [options]\n\n" &
          "  matrix    Generate a CI build matrix\n" &
          "  markdown  Generate package documentation\n" &
          "  manpage   Generate website Markdown from a manpage\n\n" &
          "Run krep generate COMMAND --help for command options.\n",
        stopWords = @["matrix", "markdown", "manpage"]],
      [rootfs], [iso, help = {
      "rootfs": "Input rootfs directory or trusted tar archive",
      "kernelVersion": "Rootfs kernel version (required when ambiguous)",
      "kernelImage": "Kernel image path inside the rootfs",
      "initramfs": "Existing compatible live initramfs; skips dracut",
      "workDir": "Existing workspace parent directory outside the input rootfs",
      "imageSizeMiB": "Ext4 image size in MiB, or 0 for automatic sizing",
      "clearRootPassword": "Explicitly clear the staged root password (insecure)",
      "name": "Output filename ending in .iso",
      "overwrite": "Atomically replace an existing output ISO",
      "initramfsGenerator": "Initramfs generator: dracut (booster is rejected for ISOs)"}],
      [disk, help = {
      "rootfs": "Input rootfs directory or trusted tar archive",
      "kernelVersion": "Rootfs kernel version (required when ambiguous)",
      "kernelImage": "Kernel image path inside the rootfs",
      "initramfs": "Existing compatible initramfs; skips generation",
      "workDir": "Existing workspace parent directory outside the input rootfs",
      "clearRootPassword": "Explicitly clear the staged root password (insecure)",
      "name": "Output filename ending in .img",
      "overwrite": "Replace existing output files",
      "initramfsGenerator": "Initramfs generator: dracut or booster",
      "partLabel": "GPT PARTLABEL of the EROFS root partition",
      "writableMounts": "Append tmpfs mounts for /var /tmp /root /home to /etc/fstab",
      "bootloader": "none (default) or grub: add a FAT32 ESP (JSESP) with GRUB, kernel and initramfs so the image boots through UEFI",
      "arch": "Target for --bootloader: aarch64 or x86_64 (default: detected from the rootfs)",
      "espSizeMiB": "ESP size in MiB with --bootloader (default 256)",
      "console": "Kernel consoles with --bootloader, e.g. 'tty0 ttyS0,115200'",
      "kernelArgs": "Extra kernel command line tokens with --bootloader"}])
  except CatchableError as exc:
    error exc.msg
    quit(1)
