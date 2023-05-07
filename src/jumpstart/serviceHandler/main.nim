# serviceHandler
# JumpStart's service handler
include ../commonImports
import enable, disable, start, stop
import os
import ../logging

proc serviceHandlerInit() =
    ## Initialize serviceHandler.
    discard existsOrCreateDir(servicePath)
    removeDir("/run/serviceHandler")
    for i in walkFiles(servicePath&"/enabled/*"):
        startService(extractFilename(i))
