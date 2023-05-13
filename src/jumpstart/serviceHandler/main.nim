# serviceHandler
# JumpStart's service handler
include ../commonImports
import enable, disable, start, stop
import os
import ../logging
import jumpmount/main
import jumpmount/umount

proc serviceHandlerInit() =
    ## Initialize serviceHandler.
    discard existsOrCreateDir(servicePath)
    removeDir("/run/serviceHandler")
    
    for i in walkFiles(mountPath&"/enabled/*.mount"):
        startMount(extractFilename(i))

    for i in walkFiles(servicePath&"/enabled/*.service"):
        startService(extractFilename(i))

