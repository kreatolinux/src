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
      "overwrite": "Atomically replace an existing output ISO"}])
  except CatchableError as exc:
    error exc.msg
    quit(1)
