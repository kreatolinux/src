## Run with -d:kpkgJournalDir=<an isolated disposable directory>.
import std/[os, tempfiles, unittest, strutils]
import ../../../kpkg/modules/[sqlite, commonPaths]

when kpkgJournalDir == "/var/lib/kpkg/journal":
  {.error: "test requires an isolated -d:kpkgJournalDir".}

when lockfilePath == "/tmp/kpkg.lock":
  {.error: "test requires an isolated -d:lockfilePath".}

suite "SQLite restore isolation":
  test "pending marker blocks cached and unopened live roots; snapshots stay readable":
    let root = createTempDir("sqlite-guard-", "")
    let other = createTempDir("sqlite-unopened-", "")
    let snapshot = root / "snapshot?#.sqlite"
    let marker = kpkgJournalDir / "test.restore"
    createDir(kpkgJournalDir)
    defer:
      closeDb()
      removeFile(marker)
      removeDir(root)
      removeDir(other)
      removeDir(kpkgJournalDir)
    discard getListPackages(root)
    snapshotDatabase(root, snapshot)
    validateDatabaseSnapshot(snapshot)
    writeFile(marker, "pending")
    expect IOError:
      discard getListPackages(root)
    expect IOError:
      discard getListPackages(other)
    check not fileExists(other / kpkgDbPath)
    validateDatabaseSnapshot(snapshot)
    check snapshotPackageVersions(snapshot).len == 0
    check not fileExists(snapshot & "-wal")
    check not fileExists(snapshot & "-shm")
    let link = root / "link.sqlite"
    createSymlink(snapshot, link)
    expect IOError:
      validateDatabaseSnapshot(link)
    writeFile(root / "empty.sqlite", "")
    expect IOError:
      validateDatabaseSnapshot(root / "empty.sqlite")
    writeFile(root / "corrupt.sqlite", repeat('x', 4096))
    expect IOError:
      validateDatabaseSnapshot(root / "corrupt.sqlite")
