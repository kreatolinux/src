import std/[unittest, os, posix, json]
import ../../../kpkg/modules/[sqlite, commonPaths]
import ../../../kpkg/modules/transactions/[main, history]

suite "persistent package history":
  test "SQLite snapshot and logical fingerprint":
    let root = getTempDir() / ("kpkg-history-db-" & $getpid())
    createDir(root)
    defer:
      closeDb()
      removeDir(root)
    discard newPackage("test", "1", "1", "0", "", "", "", "", "", "", true,
        false, false, root)
    let fingerprint = databaseFingerprint(root)
    snapshotDatabase(root, root / "snapshot.sqlite")
    closeDb()
    check fileExists(root / "snapshot.sqlite")
    check databaseFingerprint(root) == fingerprint

  test "history lists and undoes a complete file and database change":
    if not isAdmin():
      skip()
    else:
      let root = getTempDir() / ("kpkg-history-test-" & $getpid())
      createDir(root)
      defer:
        closeDb()
        removeDir(root)
      discard newPackage("old", "1", "1", "0", "", "", "", "", "", "", true,
          false, false, root)
      let session = beginHistory(root)
      let tx = newTransaction("history-test-" & $getpid(), root)
      let payload = root / "payload"
      tx.recordFileCreated(payload)
      writeFile(payload, "new")
      discard newPackage("new", "1", "1", "0", "", "", "", "", "", "", true,
          false, false, root)
      finishHistory(session, @[tx])
      tx.commit()
      check listHistory(root).len == 1
      undoHistory(tx.id, root)
      check not fileExists(payload)
      check packageExistsExact("old", root)
      check not packageExistsExact("new", root)
      check listHistory(root)[0].state == "undone"
      removeFile(tx.journalPath)
      removeDir(kpkgBackupDir / tx.id)

  test "actions are inferred from old snapshot entries":
    let root = getTempDir() / ("kpkg-history-actions-" & $getpid())
    createDir(root)
    defer:
      closeDb()
      removeDir(root)
    discard newPackage("same", "1", "1", "0", "", "", "", "", "", "", true,
        false, false, root)
    discard newPackage("up", "1", "1", "0", "", "", "", "", "", "", true, false,
        false, root)
    discard newPackage("down", "2", "1", "0", "", "", "", "", "", "", true,
        false, false, root)
    discard newPackage("gone", "1", "1", "0", "", "", "", "", "", "", true,
        false, false, root)
    snapshotDatabase(root, root / "before.sqlite")
    for name in ["up", "down", "gone"]: rmPackage(name, root)
    discard newPackage("up", "2", "1", "0", "", "", "", "", "", "", true, false,
        false, root)
    discard newPackage("down", "1", "1", "0", "", "", "", "", "", "", true,
        false, false, root)
    discard newPackage("new", "1", "1", "0", "", "", "", "", "", "", true,
        false, false, root)
    snapshotDatabase(root, root / "after.sqlite")
    # Include every changed package when classifying an actual batch.
    let mixed = %* {"hadDatabase": true, "afterDatabase": true, "packages": [
        "up", "down", "same", "gone", "new"]}
    check historyAction(root, mixed) == "mixed"
    # Isolated single-package before/after fixtures.
    closeDb()
    removeFile(root / "before.sqlite")
    removeFile(root / "after.sqlite")
    snapshotDatabase(root, root / "before.sqlite")
    snapshotDatabase(root, root / "after.sqlite")
    let data = %* {"hadDatabase": true, "afterDatabase": true, "packages": ["same"]}
    check historyAction(root, data) == "reinstall"
    removeFile(root / "before.sqlite")
    check historyAction(root, data) == "unknown"
