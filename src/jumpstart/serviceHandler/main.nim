# serviceHandler
# JumpStart's service handler
include ../commonImports
include enable, disable, start, stop
import os

proc serviceHandlerInit() =
    ## Initialize serviceHandler.
    discard existsOrCreateDir(servicePath)
    for i in walkFiles(servicePath"/*"):
        echo i
    

proc getStat(service: string): string = 
    ## Get status of an service.
    echo service
    