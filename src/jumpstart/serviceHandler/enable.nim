import os
include ../commonImports
import ../logging

proc enableService*(service: string, isMount: bool) =
    ## Enables an service.
    
    var srvmntPath: string

    if isMount:
        srvmntPath = mountPath
    else:
        srvmntPath = servicePath

    if dirExists(srvmntPath&"/enabled/"&service):
        info_msg "Service/Mount "&service&" is already enabled, no need to re-enable"
        return

    try:
        discard existsOrCreateDir(srvmntPath&"/enabled")
        createSymlink(srvmntPath&"/"&service, srvmntPath&"/enabled/"&service)
        ok "Enabled "&service
    except CatchableError:
        warn "Couldn't enable "&service&", what is going on?"
