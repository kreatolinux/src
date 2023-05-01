import cligen
import std/net
include commonImports

let socket = newSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)

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
    ## Enable service.
    connectSock()
    if now:
        sendSock("""{ "client": { "name": "Jumpstart CLI", "version": """"&clCfg.version&"""" }, "service": { "name": """"&service[
                0]&""".service", "action": "enable", "now": "true" }}""")
    else:
        sendSock("""{ "client": { "name": "Jumpstart CLI", "version": """"&clCfg.version&"""" }, "service": { "name": """"&service[
                0]&""".service", "action": "enable", "now": "false" }}""")
    echo("jumpstart: enabled service "&service[0])

proc disable(service: seq[string], now = false) =
    ## Disable service.
    connectSock()
    if now:
        sendSock("""{ "client": { "name": "Jumpstart CLI", "version": """"&clCfg.version&"""" }, "service": { "name": """"&service[
                0]&""".service", "action": "disable", "now": "true" }}""")
    else:
        sendSock("""{ "client": { "name": "Jumpstart CLI", "version": """"&clCfg.version&"""" }, "service": { "name": """"&service[
                0]&""".service", "action": "disable", "now": "false" }}""")
    echo("jumpstart: disabled service "&service[0])

proc start(service: seq[string]) =
    ## Start service.
    connectSock()
    sendSock("""{ "client": { "name": "Jumpstart CLI", "version": """"&clCfg.version&"""" }, "service": { "name": """"&service[
            0]&""".service", "action": "start", "now": "false" }}""")
    echo("jumpstart: started service "&service[0])

proc stop(service: seq[string]) =
    ## Stop service.
    connectSock()
    sendSock("""{ "client": { "name": "Jumpstart CLI", "version": """"&clCfg.version&"""" }, "service": { "name": """"&service[
            0]&""".service", "action": "stop", "now": "false" }}""")
    echo("jumpstart: stopped service "&service[0])

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
    ]
)
