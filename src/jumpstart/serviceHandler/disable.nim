import os
include ../commonImports
import ../logging

proc disableService*(service: string) =
    ## Disables an service.
    if fileExists(servicePath&"/enabled/"&service):
        removeFile(servicePath&"/enabled/"&service)
        ok "Disabled service "&service
    else:
        info_msg "Service "&service&" is already disabled"