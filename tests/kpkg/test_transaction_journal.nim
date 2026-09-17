import unittest
import os
import strutils
import sequtils
import json
import posix
import ../../kpkg/modules/transaction
import ../../kpkg/modules/commonPaths

suite "append-only transaction journal":
  test "records append and rollback restores original file":
    if not isAdmin():
      skip()
    let root = "/tmp/kpkg-tx-test-" & $getpid()
    let target = root & "/payload"
    createDir(root)
    writeFile(target, "original")

    let tx = newTransaction("journal-test-" & $getpid(), root)
    let backup = tx.backupFile(target)
    tx.recordFileReplaced(target, backup)
    writeFile(target, "replacement")
    tx.recordFileCreated(target)

    let records = readFile(tx.journalPath).splitLines().filterIt(it.len > 0)
    check records.len == 3
    check parseJson(records[0])["record"].getStr() == "header"
    check parseJson(records[1])["record"].getStr() == "operation"
    check parseJson(records[2])["record"].getStr() == "operation"

    tx.rollback()
    check readFile(target) == "original"
    let finalRecords = readFile(tx.journalPath).splitLines().filterIt(it.len > 0)
    check parseJson(finalRecords[^1])["state"].getStr() == "tsRolledBack"

    if fileExists(tx.journalPath):
      removeFile(tx.journalPath)
    if dirExists(root):
      removeDir(root)

  test "commit removes append-only journal":
    if not isAdmin():
      skip()
    let root = "/tmp/kpkg-tx-commit-" & $getpid()
    createDir(root)
    let tx = newTransaction("journal-commit-test-" & $getpid(), root)
    tx.recordFileCreated(root & "/new-file")
    writeFile(root & "/new-file", "new")
    tx.commit()
    check not fileExists(tx.journalPath)
    if dirExists(root):
      removeDir(root)

  test "reloaded journal restores empty directories with original metadata":
    if not isAdmin():
      skip()
    let root = "/tmp/kpkg-tx-directory-" & $getpid()
    let empty = root & "/etc/security/limits.d"
    createDir(empty)
    doAssert posix.chmod(empty.cstring, Mode(0o750)) == 0
    doAssert posix.chown(empty.cstring, Uid(123), Gid(456)) == 0
    let tx = newTransaction("journal-dir-test-" & $getpid(), root)
    tx.recordDirDeleted(empty)
    removeDir(empty)
    # Reinstallation creates the directory with different metadata.
    createDir(empty)
    tx.recordDirCreated(empty)
    doAssert posix.chmod(empty.cstring, Mode(0o755)) == 0
    # Rollback via a reloaded journal, as batch failure/crash recovery does.
    let loaded = getActiveTransactions().filterIt(it.id == tx.id)[0]
    loaded.rollback()
    check dirExists(empty)
    var st: Stat
    check posix.stat(empty.cstring, st) == 0
    check (int(st.st_mode) and 0o7777) == 0o750
    check st.st_uid == Uid(123)
    check st.st_gid == Gid(456)
    tx.commit() # Close the original journal handle and clean its record.
    removeDir(root)

  test "rollback restores removed nested directory without file backups":
    if not isAdmin():
      skip()
    let root = "/tmp/kpkg-tx-nested-" & $getpid()
    let parent = root & "/usr/lib/modprobe.d"
    let empty = parent & "/empty"
    createDir(empty)
    let tx = newTransaction("journal-nested-test-" & $getpid(), root)
    tx.recordDirDeleted(parent)
    tx.recordDirDeleted(empty)
    removeDir(parent)
    tx.rollback()
    check dirExists(parent)
    check dirExists(empty)
    removeFile(tx.journalPath)
    removeDir(root)
