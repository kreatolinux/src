# serviceHandler
# JumpStart's service handler
include ../commonImports
include enable, disable, start, stop
import os, osproc
import parsecfg
import ../logging

proc serviceHandlerInit() =
    ## Initialize serviceHandler.
    discard existsOrCreateDir(servicePath)
    var service: Config
    for i in walkFiles(servicePath&"/*"):
        try:
            service = loadConfig(i)
        except Exception:
            warn "Service "&i&" couldn't be loaded, possibly broken configuration?"

        discard execProcess(service.getSectionValue("Service", "exec"))

proc getStat(service: string): string =
    ## Get status of an service.
    echo service
