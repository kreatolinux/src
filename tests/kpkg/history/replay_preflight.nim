import std/[unittest, os, json]
import ../../../kpkg/modules/[commonPaths]
import ../../../kpkg/modules/transactions/main

suite "restore intent preflight":
  test "malformed later steps and foreign targets leave earlier files unchanged":
    for failure in ["version", "unknown", "write", "foreign", "directory", "staging"]:
      let root = getTempDir() / ("kpkg-preflight-" & $getCurrentProcessId() & failure)
      createDir(root)
      let target = root / "payload"
      writeFile(target, "unchanged")
      let tx = newTransaction("preflight-" & failure & "-" &
          $getCurrentProcessId(), root)
      tx.recordFileCreated(target)
      let marker = tx.journalPath & ".restore"
      let op = %* {"kind": "opFileCreated", "path": target, "backupPath": "",
          "timestamp": 0.0}
      var steps = %* [{"type": "file", "operation": op}]
      var plan = %* {"version": 1, "root": root, "cursor": 0, "steps": steps}
      case failure
      of "version": plan["version"] = %99
      of "unknown": steps.add( %* {"type": "unknown"})
      of "write": steps.add( %* {"type": "write", "path": tx.journalPath})
      of "foreign": steps.add( %* {"type": "remove", "path": root / "foreign"})
      of "directory":
        let directory = root / "directory"
        createDir(directory)
        tx.recordFileCreated(directory)
        steps.add( %* {"type": "file", "operation": {"kind": "opFileCreated",
            "path": directory, "backupPath": "", "timestamp": 0.0}})
      of "staging":
        let backup = tx.backupFile(target)
        tx.recordFileReplaced(target, backup)
        steps.add( %* {"type": "file", "operation": {"kind": "opFileReplaced",
            "path": target, "backupPath": backup, "timestamp": 0.0,
            "stagingPath": root / "foreign"}})
      else: discard
      writeFile(marker, $plan)
      let evidence = readFile(marker)
      try:
        expect CatchableError: replayHistoryRestore(marker)
        check readFile(target) == "unchanged"
        check readFile(marker) == evidence
      finally:
        removeFile(marker)
        tx.closeJournal()
        removeFile(tx.journalPath)
        if dirExists(kpkgBackupDir / tx.id): removeDir(kpkgBackupDir / tx.id)
        removeDir(root)

  test "reverse simulation rejects a restored child in a directory scheduled for removal":
    let root = getTempDir() / ("kpkg-preflight-reverse-" & $getCurrentProcessId())
    let directory = root / "tree"
    createDir(directory)
    let payload = root / "payload"
    writeFile(payload, "unchanged")
    let child = directory / "child"
    writeFile(child, "original")
    let tx = newTransaction("preflight-reverse-" & $getCurrentProcessId(), root)
    tx.recordFileCreated(payload)
    tx.recordDirCreated(directory)
    let backup = tx.backupFile(child)
    tx.recordFileDeleted(child, backup)
    removeFile(child)
    let marker = tx.journalPath & ".restore"
    let steps = %* [
      {"type": "file", "operation": {"kind": "opFileCreated", "path": payload,
          "backupPath": "", "timestamp": 0.0}},
      {"type": "file", "operation": {"kind": "opFileDeleted", "path": child,
          "backupPath": backup, "timestamp": 0.0,
          "stagingPath": newRestoreStaging(child)}},
      {"type": "file", "operation": {"kind": "opDirCreated", "path": directory,
          "backupPath": "", "timestamp": 0.0}}]
    writeFile(marker, $( %* {"version": 1, "root": root, "cursor": 0,
        "steps": steps}))
    let evidence = readFile(marker)
    try:
      expect CatchableError: replayHistoryRestore(marker)
      check readFile(payload) == "unchanged"
      check not fileExists(child)
      check readFile(marker) == evidence
    finally:
      removeFile(marker)
      tx.closeJournal()
      removeFile(tx.journalPath)
      removeDir(kpkgBackupDir / tx.id)
      removeDir(root)
