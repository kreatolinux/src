import os
import terminal

proc info*(info: string, exitAfterwards = false) =
    ## Handles info messages.
    styledEcho("kpkg: ", fgBlue, "info: ", fgDefault, info)
    if exitAfterwards:
        quit(0)

proc err*(error: string, removeLockFile = true) =
    ## Handles errors.
    styledEcho("kpkg: ", fgRed, "error: ", fgDefault, error)
    if removeLockFile:
        info "removing lockfile"
        removeFile("/tmp/kpkg.lock")
    quit(1)

proc warn*(warn: string) =
    ## Handles warnings.
    styledEcho("kpkg: ", fgYellow, "warning: ", fgDefault, warn)

proc debug*(debug: string) =
    ## Handles debug messages.
    when not defined(release):
      styledEcho("kpkg: ", fgYellow, "debug: ", fgDefault, debug)

proc success*(success: string, exitAfterwards = false) =
    ## Handles success messages.
    styledEcho("kpkg: ", fgGreen, "success: ", fgDefault, success)
    if exitAfterwards:
        quit(0)

