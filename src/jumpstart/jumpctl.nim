import cligen
import std/net
import os
include commonImports

let socket = newSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)


proc serviceName(service: seq[string]): tuple[name: string, isMount: bool] =
    ## Convenience proc to check the reported service name.
    case splitFile(service[0]).ext:
        of "":
            return (name: service[0]&".service", isMount: false)
        of ".service":
            return (name: service[0], isMount: false)
        of ".mount":
            return (name: service[0], isMount: true)
    

proc connectSock(sockPath = sockPath) =
    ## Connect to UNIX socket.
    try:
        socket.connectUnix(sockPath)
    except CatchableError:
        echo "jumpstart: daemon not running"
        quit(1)

proc sendSock(message: string) =
    ## Send information to the UNIX socket.
    socket.send(message&"\c\l")

proc enable(service: seq[string], now = false) =
    ## Enable the service.
    connectSock()

    let srvName = serviceName(service)

    if now:
        sendSock("""{ "client": { "name": "Jumpstart CLI", "version": """"&clCfg.version&"""" }, "service": { "name": """"&srvName.name&"""", "action": "enable", "now": "true" }}""")
    else:
        sendSock("""{ "client": { "name": "Jumpstart CLI", "version": """"&clCfg.version&"""" }, "service": { "name": """"&srvName.name&"""", "action": "enable", "now": "false" }}""")
    echo("jumpstart: enabled service "&service[0])

proc disable(service: seq[string], now = false) =
    ## Disable the service.
    connectSock()

    let srvName = serviceName(service)

    if now:
        sendSock("""{ "client": { "name": "Jumpstart CLI", "version": """"&clCfg.version&"""" }, "service": { "name": """"&srvName.name&"""", "action": "disable", "now": "true" }}""")
    else:
        sendSock("""{ "client": { "name": "Jumpstart CLI", "version": """"&clCfg.version&"""" }, "service": { "name": """"&srvName.name&"""", "action": "disable", "now": "false" }}""")
    echo("jumpstart: disabled service "&service[0])

proc start(service: seq[string]) =
    ## Start the service.
    connectSock()

    let srvName = serviceName(service)
    
    sendSock("""{ "client": { "name": "Jumpstart CLI", "version": """"&clCfg.version&"""" }, "service": { "name": """"&srvName.name&"""", "action": "start", "now": "false" }}""")
    echo("jumpstart: started service "&service[0])

proc stop(service: seq[string]) =
    ## Stop the service.
    connectSock()
    
    let srvName = serviceName(service)

    sendSock("""{ "client": { "name": "Jumpstart CLI", "version": """"&clCfg.version&"""" }, "service": { "name": """"&srvName.name&"""", "action": "stop", "now": "false" }}""")
    echo("jumpstart: stopped service "&service[0])

proc status(service: seq[string]) =
    ## Check status of the service.
    
    let srvName = serviceName(service)

    var status: string

    try:
        if srvName.isMount:
            status = readFile("/run/serviceHandler/mounts/"&srvName.name&"/status")
        else:
            status = readFile("/run/serviceHandler/"&srvName.name&"/status")
    except CatchableError:
        status = "stopped"

    echo "jumpstart: service is reporting status as '"&status&"'"

clCfg.version = jumpstartVersion

dispatchMulti(
    [
        enable, help = {
            "service": "The service that will be enabled.",
            "now": "Start the service after being enabled."
        }
    ],
    [
        disable, help = {
            "service": "The service that will be disabled.",
            "now": "Stop the service after being disabled."
        }
    ],
    [
        start, help = {
            "service": "The service that will be started."
        }
    ],
    [
        stop, help = {
            "service": "The service that will be stopped."
        }
    ],
    [
        status, help = {
           "service": "The service that will be reported."
        }
    ]
)
