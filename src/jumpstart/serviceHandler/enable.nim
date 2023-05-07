import os
include ../commonImports
import ../logging

proc enableService*(service: string) =
    ## Enables an service.

    if dirExists(servicePath&"/enabled/"&service):
        info_msg "Service "&service&" is already enabled, no need to re-enable"
        return

    try:
        discard existsOrCreateDir(servicePath&"/enabled")
        createSymlink(servicePath&"/"&service, servicePath&"/enabled/"&service)
        ok "Enabled "&service
    except CatchableError:
        warn "Couldn't enable "&service&", what is going on?"
