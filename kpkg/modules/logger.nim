import os
import terminal

proc err*(error: string, removeLockFile = true) =
    ## Handles errors.
    styledEcho("kpkg: ", fgRed, "error: ", fgDefault, error)
    if removeLockFile:
        echo "kpkg: removing lockfile"
        removeFile("/tmp/kpkg.lock")
    quit(1)

proc warn*(warn: string) =
    ## Handles warnings.
    styledEcho("kpkg: ", fgYellow, "warning: ", fgDefault, warn)

proc success*(success: string, exitAfterwards = false) =
    ## Handles success messages.
    styledEcho("kpkg: ", fgGreen, "success: ", fgDefault, success)
    if exitAfterwards:
      quit(0)

proc info*(info: string, exitAfterwards = false) =
    ## Handles info messages.
    styledEcho("kpkg: ", fgBlue, "info: ", fgDefault, info)
    if exitAfterwards:
      quit(0)
      
