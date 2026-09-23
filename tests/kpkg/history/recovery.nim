import std/[unittest, os, json, posix]
import ../../../kpkg/modules/[sqlite, commonPaths, lockfile]
import ../../../kpkg/modules/transactions/[main, history, barrier]

suite "abandoned history recovery":
  test "restores package files and database snapshot, including absent database":
    for hadDatabase in [false, true]:
      let root = getTempDir() / ("kpkg-history-recovery-" &
          $getCurrentProcessId() & "-" & $hadDatabase)
      createDir(root / "var/lib/kpkg")
      createLockfile()
      try:
        if hadDatabase:
          discard newPackage("original", "1", "1", "0", "", "", "", "", "", "",
              true, false, false, root)
        let originalDatabase = databaseFingerprint(root)
        let session = beginHistory(root)
        let tx = newTransaction("pending-recovery-" & $getCurrentProcessId() &
            "-" & $hadDatabase, root)
        let payload = root / "payload"
        tx.recordFileCreated(payload)
        writeFile(payload, "uncommitted")
        discard newPackage("interrupted", "1", "1", "0", "", "", "", "", "", "",
            true, false, false, root)
        closeDb()
        releaseHistoryOwnership()
        check inspectPendingHistory(root).len > 0
        check fileExists(payload)
        check dirExists(session.path)
        check recoverPendingHistory(root) == 1
        check not fileExists(payload)
        check not fileExists(session.path / "pending.json")
        check databaseFingerprint(root) == originalDatabase
        check inspectPendingHistory(root).len == 0
        check recoverPendingHistory(root) == 0
        if fileExists(tx.journalPath): removeFile(tx.journalPath)
        if dirExists(kpkgBackupDir / tx.id): removeDir(kpkgBackupDir / tx.id)
      finally:
        closeDb()
        removeLockfile()
        removeDir(root)

  test "unsafe metadata, hooks, missing snapshots and shared paths refuse without changes":
    for reason in ["legacy", "hook", "snapshot", "shared"]:
      let root = getTempDir() / ("kpkg-history-refuse-" & $getCurrentProcessId() & reason)
      createDir(root / "var/lib/kpkg")
      createLockfile()
      var txs: seq[Transaction]
      try:
        discard newPackage("original", "1", "1", "0", "", "", "", "", "", "",
            true, false, false, root)
        let session = beginHistory(root)
        let payload = root / "payload"
        let tx = newTransaction("refuse-" & reason & "-" & $getCurrentProcessId(), root)
        txs.add(tx)
        tx.recordFileCreated(payload)
        writeFile(payload, "unchanged")
        case reason
        of "legacy":
          var marker = parseJson(readFile(session.path / "pending.json"))
          marker.delete("version")
          writeFile(session.path / "pending.json", $marker)
        of "hook": markHistoryBarrier(root, "test hook effects")
        of "snapshot": removeFile(session.path / "before.sqlite")
        of "shared":
          let other = newTransaction("other-" & $getCurrentProcessId(), root)
          txs.add(other)
          other.recordFileCreated(payload)
        else: discard
        closeDb()
        let before = databaseFingerprint(root)
        releaseHistoryOwnership()
        expect CatchableError: discard recoverPendingHistory(root)
        check readFile(payload) == "unchanged"
        check databaseFingerprint(root) == before
        check fileExists(session.path / "pending.json")
      finally:
        closeDb()
        removeLockfile()
        for tx in txs:
          if fileExists(tx.journalPath): removeFile(tx.journalPath)
          if dirExists(kpkgBackupDir / tx.id): removeDir(kpkgBackupDir / tx.id)
        removeDir(root)

  test "interrupted recovery resumes its durable plan under the next lock":
    for point in ["database", "applied", "cursor"]:
      let root = getTempDir() / ("kpkg-history-resume-" & $getCurrentProcessId() & point)
      createDir(root / "var/lib/kpkg")
      createLockfile()
      let session = beginHistory(root)
      let tx = newTransaction("resume-" & point & "-" & $getCurrentProcessId(), root)
      let payload = root / "payload"
      tx.recordFileCreated(payload)
      writeFile(payload, "uncommitted")
      discard newPackage("interrupted", "1", "1", "0", "", "", "", "", "", "",
          true, false, false, root)
      closeDb()
      releaseHistoryOwnership()
      historyFaultPoint = point
      historyFaultCountdown = 0
      expect IOError: discard recoverPendingHistory(root)
      check hasHistoryRestore()
      historyFaultPoint = ""
      removeLockfile()
      createLockfile()
      try:
        check not hasHistoryRestore()
        check not fileExists(payload)
        check not fileExists(root / kpkgDbPath)
        check not fileExists(session.path / "pending.json")
        check recoverPendingHistory(root) == 0
      finally:
        closeDb()
        removeLockfile()
        if fileExists(tx.journalPath): removeFile(tx.journalPath)
        if dirExists(kpkgBackupDir / tx.id): removeDir(kpkgBackupDir / tx.id)
        removeDir(root)

  test "lock acquisition preserves legacy pending journals for manual recovery":
    let root = getTempDir() / ("kpkg-history-legacy-lock-" &
        $getCurrentProcessId())
    createDir(root / "var/lib/kpkg")
    createLockfile()
    let tx = newTransaction("legacy-lock-" & $getCurrentProcessId(), root)
    let payload = root / "payload"
    tx.recordFileCreated(payload)
    writeFile(payload, "legacy uncommitted")
    let pending = root / "var/lib/kpkg/history/pending-legacy"
    createDir(pending)
    writeFile(pending / "pending.json", $( %* {"root": root}))
    let journalBefore = readFile(tx.journalPath)
    removeLockfile()
    createLockfile()
    try:
      check readFile(payload) == "legacy uncommitted"
      check readFile(tx.journalPath) == journalBefore
      check fileExists(pending / "pending.json")
      expect IOError: discard recoverPendingHistory(root)
      check readFile(tx.journalPath) == journalBefore
    finally:
      removeLockfile()
      if fileExists(tx.journalPath): removeFile(tx.journalPath)
      if dirExists(kpkgBackupDir / tx.id): removeDir(kpkgBackupDir / tx.id)
      removeDir(root)

  test "mixed commit batch restores while finalized entry preserves installation":
    for finalized in [false, true]:
      let root = getTempDir() / ("kpkg-history-finalize-" &
          $getCurrentProcessId() & $finalized)
      createDir(root / "var/lib/kpkg")
      createLockfile()
      var txs: seq[Transaction]
      try:
        let session = beginHistory(root)
        for index in 0..1:
          let tx = newTransaction("mixed-" & $index & "-" &
              $getCurrentProcessId() & $finalized, root)
          txs.add(tx)
          tx.recordFileCreated(root / $index)
          writeFile(root / $index, "installed")
        discard newPackage("installed", "1", "1", "0", "", "", "", "", "", "",
            true, false, false, root)
        var batch = ""
        if finalized:
          batch = beginBatchJournal("finalized-" & $getCurrentProcessId(), root,
              root / kpkgDbPath, "", false)
          let pendingBytes = readFile(session.path / "pending.json")
          finishHistory(session, txs)
          check not fileExists(batch)
          durableWrite(session.path / "pending.json", pendingBytes)
        else:
          txs[0].commit()
        closeDb()
        releaseHistoryOwnership()
        check recoverPendingHistory(root) == 1
        check not fileExists(session.path / "pending.json")
        for index in 0..1: check fileExists(root / $index) == finalized
        if finalized:
          check packageExistsExact("installed", root)
          check fileExists(session.path / "entry.json")
        else:
          check not fileExists(root / kpkgDbPath)
        check recoverPendingHistory(root) == 0
      finally:
        closeDb()
        removeLockfile()
        for tx in txs:
          if fileExists(tx.journalPath): removeFile(tx.journalPath)
          if dirExists(kpkgBackupDir / tx.id): removeDir(kpkgBackupDir / tx.id)
        removeDir(root)

  test "missing inventory members and duplicate journal identities refuse":
    for damage in ["missing", "duplicate"]:
      let root = getTempDir() / ("kpkg-history-inventory-" &
          $getCurrentProcessId() & damage)
      createDir(root / "var/lib/kpkg")
      createLockfile()
      let session = beginHistory(root)
      let tx = newTransaction("inventory-" & damage & "-" &
          $getCurrentProcessId(), root)
      let payload = root / "payload"
      tx.recordFileCreated(payload)
      writeFile(payload, "preserve evidence")
      tx.commit()
      let other = newTransaction("inventory-other-" & damage & "-" &
          $getCurrentProcessId(), root)
      other.recordFileCreated(root / "other")
      writeFile(root / "other", "preserve other")
      other.commit()
      let duplicate = kpkgJournalDir / ("duplicate-" & tx.id & ".journal")
      if damage == "missing": removeFile(tx.journalPath)
      else: copyFile(tx.journalPath, duplicate)
      releaseHistoryOwnership()
      try:
        expect IOError: discard recoverPendingHistory(root)
        check readFile(payload) == "preserve evidence"
        check readFile(root / "other") == "preserve other"
        check fileExists(session.path / "pending.json")
        check not hasHistoryRestore()
      finally:
        removeLockfile()
        if fileExists(tx.journalPath): removeFile(tx.journalPath)
        if fileExists(duplicate): removeFile(duplicate)
        if fileExists(other.journalPath): removeFile(other.journalPath)
        if dirExists(kpkgBackupDir / other.id): removeDir(kpkgBackupDir / other.id)
        if dirExists(kpkgBackupDir / tx.id): removeDir(kpkgBackupDir / tx.id)
        removeDir(root)

  test "foreign-root batch cannot be retired through matching history path":
    let root = getTempDir() / ("kpkg-history-foreign-batch-" &
        $getCurrentProcessId())
    createDir(root / "var/lib/kpkg")
    createLockfile()
    let session = beginHistory(root)
    let batch = beginBatchJournal("foreign-" & $getCurrentProcessId(), root,
        root / kpkgDbPath, "", false)
    var data = parseJson(readFile(batch))
    data["root"] = %(root & "-foreign")
    durableWrite(batch, $data)
    let before = readFile(batch)
    releaseHistoryOwnership()
    try:
      expect IOError: discard recoverPendingHistory(root)
      check readFile(batch) == before
      check fileExists(session.path / "pending.json")
      check not hasHistoryRestore()
    finally:
      removeLockfile()
      if fileExists(batch): removeFile(batch)
      removeDir(root)

  test "cache snapshot restores content and mode":
    let root = getTempDir() / ("kpkg-history-cache-" & $getCurrentProcessId())
    createDir(root / "etc")
    let cache = root / "etc/ld.so.cache"
    writeFile(cache, "original cache")
    let mode = {fpUserRead, fpUserWrite, fpGroupRead}
    setFilePermissions(cache, mode)
    check chown(cache.cstring, Uid(1234), Gid(2345)) == 0
    check chmod(cache.cstring, Mode(0o6640)) == 0
    createLockfile()
    let session = beginHistory(root)
    writeFile(cache, "mutated cache")
    setFilePermissions(cache, {fpUserRead})
    check chown(cache.cstring, Uid(0), Gid(0)) == 0
    releaseHistoryOwnership()
    try:
      check recoverPendingHistory(root) == 1
      check readFile(cache) == "original cache"
      check getFilePermissions(cache) == mode
      var metadata: Stat
      check lstat(cache.cstring, metadata) == 0
      check metadata.st_uid == Uid(1234)
      check metadata.st_gid == Gid(2345)
      check (metadata.st_mode and Mode(0o7777)) == Mode(0o6640)
      check not fileExists(session.path / "pending.json")
    finally:
      removeLockfile()
      removeDir(root)

  test "cache symlink snapshot preserves target and non-root ownership":
    let root = getTempDir() / ("kpkg-history-cache-link-" &
        $getCurrentProcessId())
    createDir(root / "etc")
    let cache = root / "etc/ld.so.cache"
    createSymlink("original-target", cache)
    check lchown(cache.cstring, Uid(1234), Gid(2345)) == 0
    createLockfile()
    discard beginHistory(root)
    removeFile(cache)
    createSymlink("new-target", cache)
    releaseHistoryOwnership()
    try:
      check recoverPendingHistory(root) == 1
      check expandSymlink(cache) == "original-target"
      var metadata: Stat
      check lstat(cache.cstring, metadata) == 0
      check metadata.st_uid == Uid(1234)
      check metadata.st_gid == Gid(2345)
    finally:
      removeLockfile()
      removeDir(root)
