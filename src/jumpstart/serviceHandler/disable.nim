import os
include ../commonImports
import ../logging

proc disableService*(service: string, isMount: bool) =
    ## Disables an service.

    var srvmntPath: string

    if isMount:
        srvmntPath = mountPath
    else:
        srvmntPath = servicePath

    if fileExists(srvmntPath&"/enabled/"&service):
        removeFile(srvmntPath&"/enabled/"&service)
        ok "Disabled service/mount "&service
    else:
        info_msg "Service/Mount "&service&" is already disabled"
