import std/[unittest, os, posix, osproc, strutils]
import ../../../kpkg/modules/[sqlite, commonPaths]
import ../../../kpkg/modules/transactions/[main, history, barrier]

if paramCount() == 1 and paramStr(1) == "--recover":
  recoverHistoryRestores()
  quit(0)

suite "durable history restore":
  test "chain resumes at durable cursor across every failure boundary":
    for point in ["copy", "metadata", "rename", "renamed", "database",
        "database-sidecars", "state", "applied", "cursor"]:
      for occurrence in 0..1:
        let root = "/tmp/kpkg-atomic-" & $getpid() & "-" & point & "-" & $occurrence
        createDir(root / "var/lib/kpkg")
        discard newPackage("base", "1", "1", "0", "", "", "", "", "", "", true,
            false, false, root)
        let originalDatabase = databaseFingerprint(root)
        closeDb()
        let payload = root / "payload"
        writeFile(payload, "original")
        createSymlink("original-target", root / "link")
        var ids: seq[string]
        for revision in 1..2:
          let session = beginHistory(root)
          let tx = newTransaction(point & "-" & $occurrence & "-" & $revision &
              "-" & $getpid(), root)
          tx.recordFileReplaced(payload, tx.backupFile(payload))
          tx.recordFileReplaced(root / "link", tx.backupFile(root / "link"))
          writeFile(payload, $revision)
          removeFile(root / "link")
          createSymlink("target-" & $revision, root / "link")
          discard newPackage("revision" & $revision, "1", "1", "0", "", "", "",
              "", "", "", true, false, false, root)
          finishHistory(session, @[tx])
          tx.commit()
          ids.add(tx.id)
        historyFaultPoint = point
        historyFaultCountdown = occurrence
        # Database copy is one step, so only occurrence zero is injectable.
        if point in ["database", "database-sidecars"] and occurrence == 1:
          historyFaultCountdown = 0
        expect IOError: undoHistory(ids[0], root)
        check hasHistoryRestore()
        expect IOError: discard cleanHistory(root, 0)
        expect IOError: discard beginHistory(root)
        expect IOError: discard newTransaction("blocked", root)
        if point in ["copy", "metadata", "rename"] and occurrence == 0:
          check readFile(payload) == "2"
          check expandSymlink(root / "link") == "target-2"
        # Simulate a new process: discard all live handles and replay only disk intent.
        closeDb()
        historyFaultPoint = ""
        let child = execCmdEx(quoteShell(getAppFilename()) & " --recover")
        check child.exitCode == 0
        check not hasHistoryRestore()
        check databaseFingerprint(root) == originalDatabase
        closeDb()
        check readFile(payload) == "original"
        check expandSymlink(root / "link") == "original-target"
        for entry in listHistory(root): check entry.state == "undone"
        for id in ids:
          check loadTransaction(kpkgJournalDir / (id & ".journal")).state == tsRolledBack
        recoverHistoryRestores() # completed recovery is a no-op
        closeDb()
        removeDir(root)
        for id in ids:
          removeFile(kpkgJournalDir / (id & ".journal"))
          removeDir(kpkgBackupDir / id)

  test "directory metadata failure replays":
    let root = "/tmp/kpkg-atomic-dir-" & $getpid()
    createDir(root / "var/lib/kpkg")
    discard newPackage("base", "1", "1", "0", "", "", "", "", "", "", true,
        false, false, root)
    createDir(root / "owned/empty")
    let session = beginHistory(root)
    let tx = newTransaction("dir-" & $getpid(), root)
    tx.recordTreeDeleted(root / "owned")
    removeDir(root / "owned")
    finishHistory(session, @[tx])
    tx.commit()
    historyFaultPoint = "metadata"
    historyFaultCountdown = 0
    expect IOError: undoHistory(tx.id, root)
    historyFaultPoint = ""
    recoverHistoryRestores()
    check dirExists(root / "owned/empty")
    check listHistory(root)[0].state == "undone"
    closeDb()
    removeDir(root)
    removeFile(kpkgJournalDir / (tx.id & ".journal"))
    removeDir(kpkgBackupDir / tx.id)

  test "corrupt snapshots refuse intent and recovery":
    let root = "/tmp/kpkg-atomic-corrupt-" & $getpid()
    createDir(root / "var/lib/kpkg")
    discard newPackage("base", "1", "1", "0", "", "", "", "", "", "", true,
        false, false, root)
    let session = beginHistory(root)
    let tx = newTransaction("corrupt-" & $getpid(), root)
    tx.recordFileCreated(root / "payload")
    writeFile(root / "payload", "new")
    finishHistory(session, @[tx])
    tx.commit()
    let image = session.path / "before.sqlite"
    let saved = readFile(image)
    writeFile(image, "not sqlite")
    expect IOError: undoHistory(tx.id, root)
    check not hasHistoryRestore()
    check readFile(root / "payload") == "new"
    writeFile(image, repeat("x", 4096))
    expect IOError: undoHistory(tx.id, root)
    check not hasHistoryRestore()
    removeFile(image)
    createSymlink(session.path / "after.sqlite", image)
    expect IOError: undoHistory(tx.id, root)
    check not hasHistoryRestore()
    removeFile(image)
    createDir(image)
    expect IOError: undoHistory(tx.id, root)
    check not hasHistoryRestore()
    removeDir(image)
    writeFile(image, saved)
    historyFaultPoint = "database-sidecars"
    historyFaultCountdown = 0
    expect IOError: undoHistory(tx.id, root)
    historyFaultPoint = ""
    check hasHistoryRestore()
    expect IOError: discard databaseFingerprint(root)
    writeFile(image, "bad recovery image")
    expect IOError: recoverHistoryRestores()
    check hasHistoryRestore()
    writeFile(image, saved)
    # Reintroduced sidecars must be removed again, even after the old cleanup ran.
    writeFile(root / kpkgDbPath & "-wal", "stale")
    writeFile(root / kpkgDbPath & "-shm", "stale")
    recoverHistoryRestores()
    check not fileExists(root / kpkgDbPath & "-wal")
    check not fileExists(root / kpkgDbPath & "-shm")
    check not hasHistoryRestore()
    closeDb()
    removeDir(root)
    removeFile(kpkgJournalDir / (tx.id & ".journal"))

  test "abandoned pending and corrupt journals fail closed":
    let root = "/tmp/kpkg-atomic-pending-" & $getpid()
    let pending = root / "var/lib/kpkg/history/pending-old"
    createDir(pending)
    writeFile(pending / "pending.json", "{}")
    expect IOError: discard beginHistory(root)
    expect IOError: discard newTransaction("blocked", root)
    removeDir(root)
    createDir(root)
    let session = beginHistory(root)
    let tx = newTransaction("owned-" & $getpid(), root)
    tx.commit()
    releaseHistoryOwnership()
    expect IOError: discard newTransaction("abandoned-same-process", root)
    expect IOError: cancelHistory(session)
    check fileExists(session.path / "pending.json")
    removeDir(session.path) # Explicit fixture cleanup, not cancellation.
    removeFile(kpkgJournalDir / (tx.id & ".journal"))
    let bad = kpkgJournalDir / "corrupt.journal"
    writeFile(bad, "{broken")
    expect IOError: discard getActiveTransactions()
    expect IOError: discard recoverFromCrash()
    removeFile(bad)
    let batch = kpkgJournalDir / "batch-corrupt.batch"
    writeFile(batch, "{broken")
    expect IOError: discard recoverFromCrash()
    check fileExists(batch)
    removeFile(batch)
    removeDir(root)

  test "legacy recovery preserves failed transaction instead of admitting mutation":
    let root = "/tmp/kpkg-atomic-legacy-" & $getpid()
    createDir(root)
    let tx = newTransaction("legacy-" & $getpid(), root)
    tx.recordFileDeleted(root / "lost", root / "missing-backup")
    tx.closeJournal()
    expect IOError: discard recoverFromCrash()
    check loadTransaction(tx.journalPath).state == tsActive
    removeFile(tx.journalPath)
    removeDir(root)
