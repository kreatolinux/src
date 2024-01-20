import os
import terminal

proc debug*(debug: string) =
    ## Handles debug messages.
    when not defined(release):
        styledEcho("kpkg: ", fgYellow, "debug: ", fgDefault, debug)

proc info*(info: string, exitAfterwards = false) =
    ## Handles info messages.
    styledEcho("kpkg: ", fgBlue, "info: ", fgDefault, info)
    if exitAfterwards:
        debug "infoProc: exiting"
        quit(0)

proc err*(error: string, removeLockFile = true) =
    ## Handles errors.
    styledEcho("kpkg: ", fgRed, "error: ", fgDefault, error)
    echo "kpkg: if you think this is a bug, please open an issue at https://github.com/kreatolinux/src"
    if removeLockFile:
        info "removing lockfile"
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

