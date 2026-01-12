import os
import logger

const lockfilePath* = "/tmp/kpkg.lock"

proc removeLockfile*() =
  ## Remove the lockfile if it exists.
  if fileExists(lockfilePath):
    removeFile(lockfilePath)

proc lockfileErrorCallback(msg: string) =
  ## Error callback that removes the lockfile on fatal errors.
  info("lockfile", "removing lockfile due to error")
  removeLockfile()

proc createLockfile*() =
  ## Create the lockfile and set up the error callback for cleanup.
  writeFile(lockfilePath, "")
  # Register the error callback so lockfile is cleaned up on fatal errors
  setErrorCallback(lockfileErrorCallback)

proc checkLockfile*() =
  ## Check if lockfile exists and error if it does.
  if fileExists(lockfilePath):
    # Don't remove lockfile on this error since we didn't create it
    error("lockfile exists, will not proceed")
    quit(1)

proc clearErrorCallback*() =
  ## Clear the error callback (call after successful operation).
  setErrorCallback(nil)
