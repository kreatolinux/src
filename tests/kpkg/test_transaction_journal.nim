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
