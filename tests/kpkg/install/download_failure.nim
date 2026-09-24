import std/[unittest, os, tempfiles, strutils]
import ../../../kpkg/commands/installcmd
import ../../../kpkg/modules/[config, lockfile, commonPaths]
import ../../../kpkg/modules/transactions/[history, barrier]

when not defined(kpkgInstallFailureTest):
  {.fatal: "compile with -d:kpkgInstallFailureTest".}

suite "install download failure":
  test "missing archives do not leave pending history or block the next command":
    let fixture = createTempDir("kpkg-download-failure-", "")
    let root = fixture / "root"
    let repo = fixture / "repo"
    createDir(root)
    defer:
      removeDir(fixture)
      if fileExists(kpkgConfigPath): removeFile(kpkgConfigPath)
    # A group is immediately ready without an archive. It must NOT install
    # while another member of the batch is missing.
    let packages = @["ready-group", "missing-archive-a", "missing-archive-b"]
    for name in packages:
      createDir(repo / name)
      writeFile(repo / name / "run3", "name: \"" & name &
          "\"\nversion: \"1.0\"\nrelease: \"1\"\n")
    writeFile(repo / "ready-group" / "run3",
        "name: \"ready-group\"\nversion: \"1.0\"\nrelease: \"1\"\nis_group: \"true\"\n")
    writeFile(kpkgConfigPath, "[Repositories]\nrepoDirs=" & repo &
        "\n[Parallelization]\ninstallThreads=2\n")
    for attempt in 0 ..< 2:
      var failed = false
      try:
        probeMissingInstallArchives(packages, root)
      except IOError as e:
        failed = true
        check "missing archives" in e.msg
      check failed
      check inspectPendingHistory(root).len == 0
      check not dirExists(root / "var/lib/kpkg/history")
      check not fileExists(root / kpkgDbPath)
      # A new lease rotates ownership, just like the next CLI invocation.
      createLockfile()
      try:
        assertNoAbandonedHistory(root)
      finally:
        removeLockfile()
