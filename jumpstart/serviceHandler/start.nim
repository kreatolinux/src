import parsecfg
import os, osproc
import std/threadpool
import status
import ../../common/logging
include ../commonImports
import globalVariables

proc startService*(serviceName: string) =
    ## Start an service.
    var service: Config

    # Load the configuration
    try:
        if dirExists("/run/serviceHandler/"&serviceName):
            warn "Service "&serviceName&" is already running, not starting it again"
            return

        createDir("/run/serviceHandler/"&serviceName)
        service = loadConfig(servicePath&"/"&serviceName)
    except CatchableError:
        warn "Service "&serviceName&" couldn't be started, possibly broken configuration?"
        return

    #var workDir: string
    #try:
    #    workDir = service.getSectionValue("Settings", "workDir")
    #except CatchableError:
    #    workDir = "/"

    createDir("/run/serviceHandler/"&serviceName)
    let processPre = startProcess(command = service.getSectionValue("Service",
        "execPre"), options = {poEvalCommand, poUsePath})

    let process = startProcess(command = service.getSectionValue("Service",
            "exec"), options = {poEvalCommand, poUsePath, poDaemon})

    services = services&(serviceName: serviceName, process: process,
            processPre: processPre)

    spawn statusDaemon(process, serviceName, service.getSectionValue("Service",
            "execPost"), options = {poEvalCommand, poUsePath, poDaemon})
    ok "Started "&serviceName
