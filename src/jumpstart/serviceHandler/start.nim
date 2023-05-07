import parsecfg
import os, osproc
import std/threadpool
import std/net
import ../logging
include ../commonImports

proc spawnSock(serviceName: string) =
    ## Creates a socket.
    let socket = newSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
    var client: Socket
    var address = ""

    try:
        socket.bindUnix("/run/serviceHandler/"&serviceName&"/sock")
    except CatchableError:
        error "cannot start, sock already in use (is another instance of jumpstart open?)"

    socket.listen()

    while true:
        socket.acceptAddr(client, address)
        echo client.recvLine()

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
    spawn spawnSock(serviceName)
    ok "Started "&serviceName
