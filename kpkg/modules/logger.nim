import os

proc err*(error: string, removeLockFile = true) =
    ## Handles errors.
    echo("kpkg: error: "&error)
    if removeLockFile:
        echo "kpkg: removing lockfile"
        removeFile("/tmp/kpkg.lock")
    quit(1)
