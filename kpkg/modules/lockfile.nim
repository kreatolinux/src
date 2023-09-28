import os
import logger

const lockfile = "/tmp/kpkg.lock"

proc createLockfile*() =
  writeFile(lockfile, "")

proc checkLockfile*() =
  if fileExists(lockfile):
    err("lockfile exists, will not proceed", false)

proc removeLockfile*() =
  removeFile(lockfile)

