import parsecfg
import os, osproc
import std/threadpool
import ../logging
include ../commonImports

proc startService*(serviceName: string) =
    ## Start an service.
    var service: Config

    # Load the configuration,
    try:
        if dirExists("/run/serviceHandler/"&serviceName):
            warn "Service "&serviceName&" is already running, not starting it again"
            return
        service = loadConfig(servicePath&"/"&serviceName)
    except CatchableError:
        warn "Service "&serviceName&" couldn't be started, possibly broken configuration?"
        return

    createDir("/run/serviceHandler/"&serviceName)
    discard spawn execProcess(service.getSectionValue("Service", "exec"))
    ok "Started "&serviceName
