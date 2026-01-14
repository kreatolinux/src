import os
import ../modules/lockfile
import ../modules/logger

proc clearLock*() =
  ## Force clear the kpkg lockfile.
  ## Use this if kpkg crashed and left a stale lockfile.
  if not isAdmin():
    error("you have to be root for this action.")
    quit(1)

  forceClearLockfile()
  quit(0)
