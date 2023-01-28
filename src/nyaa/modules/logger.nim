proc err(error: string, removeLockFile = true) =
    ## Handles errors.
    echo("nyaa: error: "&error)
    if removeLockFile:
        echo "nyaa: removing lockfile"
        removeFile("/tmp/nyaa.lock")
    quit(1)
