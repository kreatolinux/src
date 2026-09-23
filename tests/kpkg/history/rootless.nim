import std/[unittest, os, posix, json, times]
import ../../../kpkg/modules/[sqlite, commonPaths]
import ../../../kpkg/modules/transactions/[main, history]

suite "rootless history safety":
  test "upgrade, removal, conflict preflight and metadata symlinks":
    let root = getTempDir() / ("kpkg-history-rootless-" & $getpid())
    createDir(root)
    defer:
      closeDb()
      removeDir(root)
    createDir(root / "var/lib/kpkg")
    discard newPackage("pkg", "1", "1", "0", "", "", "", "", "", "", true,
        false, false, root)
    let metadata = root / "var/cache/kpkg/installed/pkg"
    createDir(metadata / "empty")
    writeFile(metadata / "run", "old metadata")
    createSymlink("missing", metadata / "link")
    let payload = root / "payload"
    writeFile(payload, "old")
    let session = beginHistory(root)
    let tx = newTransaction("upgrade-" & $getpid(), root)
    tx.recordTreeDeleted(metadata)
    tx.recordFileReplaced(payload, tx.backupFile(payload))
    removeDir(metadata)
    tx.recordDirCreated(metadata)
    createDir(metadata)
    tx.recordFileCreated(metadata / "run")
    writeFile(metadata / "run", "new metadata")
    writeFile(payload, "new")
    finishHistory(session, @[tx])
    tx.commit()
    writeFile(payload, "edited")
    expect IOError: undoHistory(tx.id, root)
    check readFile(metadata / "run") == "new metadata"
    writeFile(payload, "new")
    undoHistory(tx.id, root)
    check readFile(payload) == "old"
    check readFile(metadata / "run") == "old metadata"
    check expandSymlink(metadata / "link") == "missing"
    check dirExists(metadata / "empty")
    let removal = beginHistory(root)
    let rt = newTransaction("remove-" & $getpid(), root)
    rt.recordTreeDeleted(metadata)
    rt.recordFileDeleted(payload, rt.backupFile(payload))
    removeDir(metadata)
    removeFile(payload)
    rmPackage("pkg", root)
    finishHistory(removal, @[rt])
    rt.commit()
    undoHistory(rt.id, root)
    check packageExistsExact("pkg", root)
    check readFile(payload) == "old"
    check readFile(metadata / "run") == "old metadata"
    for journal in [tx, rt]:
      removeFile(journal.journalPath)
      removeDir(kpkgBackupDir / journal.id)

  test "untracked descendants and pending operations refuse before restore":
    let root = getTempDir() / ("kpkg-history-refusal-" & $getpid())
    createDir(root)
    defer:
      closeDb()
      removeDir(root)
    let session = beginHistory(root)
    let tx = newTransaction("refusal-" & $getpid(), root)
    let directory = root / "newdir"
    tx.recordDirCreated(directory)
    createDir(directory)
    discard newPackage("pkg", "1", "1", "0", "", "", "", "", "", "", true,
        false, false, root)
    finishHistory(session, @[tx])
    tx.commit()
    createDir(directory / "external")
    expect IOError: undoHistory(tx.id, root)
    check packageExistsExact("pkg", root)
    removeDir(directory / "external")
    let pending = beginHistory(root)
    expect IOError: undoHistory(tx.id, root)
    cancelHistory(pending)
    undoHistory(tx.id, root)
    check not fileExists(root / kpkgDbPath)
    removeFile(tx.journalPath)
    removeDir(kpkgBackupDir / tx.id)

  test "rollback retains target batch and undo checks ancestor symlinks":
    let root = getTempDir() / ("kpkg-history-chain-" & $getpid())
    createDir(root / "owned")
    defer:
      closeDb()
      removeDir(root)
    var journals: seq[Transaction]
    for n in 1 .. 2:
      let session = beginHistory(root)
      let tx = newTransaction("chain-" & $n & "-" & $getpid(), root)
      journals.add(tx)
      let payload = root / "owned/payload"
      if fileExists(payload): tx.recordFileReplaced(payload, tx.backupFile(payload))
      else: tx.recordFileCreated(payload)
      writeFile(payload, $n)
      discard newPackage("pkg" & $n, "1", "1", "0", "", "", "", "", "", "",
          true, false, false, root)
      finishHistory(session, @[tx])
      tx.commit()
    rollbackHistory(journals[0].id, root)
    check readFile(root / "owned/payload") == "1"
    check packageExistsExact("pkg1", root)
    check not packageExistsExact("pkg2", root)
    moveDir(root / "owned", root / "moved")
    createSymlink("moved", root / "owned")
    expect IOError: undoHistory(journals[0].id, root)
    check readFile(root / "moved/payload") == "1"
    removeFile(root / "owned")
    moveDir(root / "moved", root / "owned")
    undoHistory(journals[0].id, root)
    check not fileExists(root / "owned/payload")
    for tx in journals:
      removeFile(tx.journalPath)
      removeDir(kpkgBackupDir / tx.id)

  test "reinstall preserves untracked files in a pre-existing directory":
    let root = getTempDir() / ("kpkg-history-reinstall-cache-" & $getpid())
    let directory = root / "lib/python/collections"
    createDir(directory)
    defer:
      closeDb()
      removeDir(root)
    let session = beginHistory(root)
    let tx = newTransaction("reinstall-cache-" & $getpid(), root)
    tx.recordDirDeleted(directory)
    removeDir(directory)
    createDir(directory)
    tx.recordDirCreated(directory & "/")
    let payload = directory / "module.py"
    tx.recordFileCreated(payload)
    writeFile(payload, "new")
    discard newPackage("pkg", "1", "1", "0", "", "", "", "", "", "", true,
        false, false, root)
    finishHistory(session, @[tx])
    tx.commit()
    createDir(directory / "__pycache__")
    writeFile(directory / "__pycache__/local.pyc", "untracked")
    undoHistory(tx.id, root)
    check dirExists(directory)
    check not fileExists(payload)
    check readFile(directory / "__pycache__/local.pyc") == "untracked"
    removeFile(tx.journalPath)
    removeDir(kpkgBackupDir / tx.id)

  test "clean prunes old history and backups but preserves recent entries":
    let root = getTempDir() / ("kpkg-history-clean-" & $getpid())
    createDir(root)
    defer:
      closeDb()
      removeDir(root)
    var txs: seq[Transaction]
    for n in 0 .. 1:
      let session = beginHistory(root)
      let tx = newTransaction("clean-" & $n & "-" & $getpid(), root)
      txs.add(tx)
      discard newPackage("pkg" & $n, "1", "1", "0", "", "", "", "", "", "",
          true, false, false, root)
      finishHistory(session, @[tx])
      tx.commit()
      if n == 0:
        let path = session.path / "entry.json"
        var data = parseJson(readFile(path))
        data["timestamp"] = %(epochTime() - 40 * 86400)
        writeFile(path, $data)
    let pending = beginHistory(root)
    expect IOError: discard cleanHistory(root, 30)
    check listHistory(root).len == 2
    cancelHistory(pending)
    expect ValueError: discard cleanHistory(root, -1)
    check cleanHistory(root, 30) == 1
    check not fileExists(txs[0].journalPath)
    check not dirExists(kpkgBackupDir / txs[0].id)
    check fileExists(txs[1].journalPath)
    check listHistory(root).len == 1
    check packageExistsExact("pkg0", root)
    check packageExistsExact("pkg1", root)
    check cleanHistory(root, 0) == 1
    check listHistory(root).len == 0
    check cleanHistory(root, 0) == 0
