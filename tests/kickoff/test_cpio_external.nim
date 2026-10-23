## Cross-checks the archive against a real cpio implementation.
##
## The unit tests in test_cpio.nim validate the format against our own reader,
## which would happily agree with a shared mistake. This test hands the bytes to
## GNU cpio and asserts it lists and extracts them. Skipped when cpio is absent,
## so it does not become a hard build dependency.

import std/[os, osproc, strutils, unittest]
import ../../kickoff/modules/cpio

proc haveCpio(): bool =
  findExe("cpio").len > 0

proc buildFixture(base: string) =
  removeDir(base)
  createDir(base / "etc")
  createDir(base / "sbin")
  writeFile(base / "etc/hostname", "klinux\n")
  writeFile(base / "sbin/init", "#!/bin/sh\necho hi\n")
  setFilePermissions(base / "sbin/init", {fpUserRead, fpUserWrite, fpUserExec,
      fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})
  createSymlink("/bin/busybox", base / "sh")

suite "cpio newc archive against GNU cpio":
  test "cpio lists every entry we wrote":
    if not haveCpio():
      skip()
    else:
      let base = getTempDir() / "kickoff-cpio-external"
      buildFixture(base)
      let archivePath = base / "out.cpio"
      writeFile(archivePath, buildArchive(scanTree(base, ".")))
      let listing = execProcess("sh", args = ["-c", "cpio -it < " & quoteShell(archivePath)],
                                options = {poUsePath})
      for expected in [".", "etc", "sbin", "etc/hostname", "sbin/init", "sh"]:
        check listing.splitLines().contains(expected)

  test "cpio extracts contents and symlinks intact":
    if not haveCpio():
      skip()
    else:
      let base = getTempDir() / "kickoff-cpio-extract"
      buildFixture(base)
      let archivePath = base / "out.cpio"
      writeFile(archivePath, buildArchive(scanTree(base, ".")))
      let dest = base / "root"
      createDir(dest)
      discard execProcess("sh", args = ["-c",
        "cd " & quoteShell(dest) & " && cpio -idm < " & quoteShell(archivePath)],
        options = {poUsePath})
      check readFile(dest / "etc/hostname") == "klinux\n"
      check readFile(dest / "sbin/init") == "#!/bin/sh\necho hi\n"
      check expandSymlink(dest / "sh") == "/bin/busybox"
      # the exec bit must survive the round trip
      check fpUserExec in getFilePermissions(dest / "sbin/init")
