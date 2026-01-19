import os
import ../modules/lockfile
import ../../common/logging
import ../modules/gitutils

proc clearLock*() =
  ## Force clear the kpkg lockfile.
  ## Use this if kpkg crashed and left a stale lockfile.
  ## Also recovers any repos that were left in a checked-out commit state.
  if not isAdmin():
    error("you have to be root for this action.")
    quit(1)

  # Recover any repos that were left in a commit-based build state
  discard recoverFromCommitBuild()

  forceClearLockfile()
  quit(0)
