import unittest
import os
import strutils
import ../../kpkg/modules/lockfile

suite "lockfile":
  setup:
    # Ensure clean state before each test
    if fileExists(lockfilePath):
      removeFile(lockfilePath)

  teardown:
    # Clean up after each test
    if fileExists(lockfilePath):
      removeFile(lockfilePath)

  test "createLockfile writes PID":
    createLockfile()
    check fileExists(lockfilePath)
    let content = readFile(lockfilePath).strip()
    check content != ""
    # Should be a valid integer
    let pid = parseInt(content)
    check pid > 0
    clearErrorCallback()
    removeLockfile()

  test "checkLockfile detects and removes stale lock":
    # Write a fake PID that doesn't exist (very high number)
    writeFile(lockfilePath, "999999999")
    check fileExists(lockfilePath)

    # checkLockfile should detect stale lock and remove it
    checkLockfile()

    # Lockfile should be removed
    check not fileExists(lockfilePath)

  test "checkLockfile removes empty lockfile":
    # Old format - empty lockfile
    writeFile(lockfilePath, "")
    check fileExists(lockfilePath)

    checkLockfile()

    check not fileExists(lockfilePath)

  test "checkLockfile removes invalid content":
    writeFile(lockfilePath, "not-a-number")
    check fileExists(lockfilePath)

    checkLockfile()

    check not fileExists(lockfilePath)

  test "forceClearLockfile removes lockfile":
    writeFile(lockfilePath, "12345")
    check fileExists(lockfilePath)

    forceClearLockfile()

    check not fileExists(lockfilePath)

  test "forceClearLockfile handles no lockfile":
    check not fileExists(lockfilePath)

    # Should not error
    forceClearLockfile()

    check not fileExists(lockfilePath)

  test "removeLockfile removes existing lockfile":
    writeFile(lockfilePath, "test")
    check fileExists(lockfilePath)

    removeLockfile()

    check not fileExists(lockfilePath)

  test "removeLockfile handles non-existent lockfile":
    check not fileExists(lockfilePath)

    # Should not error
    removeLockfile()

    check not fileExists(lockfilePath)
