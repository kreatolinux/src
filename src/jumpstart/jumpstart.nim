import std/net
import json
include serviceHandler/main

let socket = newSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)

try:
    socket.bindUnix(sockPath)
except CatchableError:
    error "cannot start, sock already in use (is another instance of jumpstart open?)"

socket.listen()

info_msg "Initializing "&jumpstartVersion


proc ctrlc() {.noconv.} =
    info_msg "removing socket"
    removeFile(sockPath)
    removeDir("/run/serviceHandler")
    info_msg "exiting"
    quit(0)

setControlCHook(ctrlc)

var client: Socket
var address = ""
serviceHandlerInit()
while true:
    socket.acceptAddr(client, address)
    var json = parseJson(client.recvLine())
    #echo pretty(json)
    var isMount: bool
    if splitFile(json["service"]["name"].getStr).ext == ".mount":
        isMount = true

    case json["service"]["action"].getStr:
        of "stop":
            if isMount:
                stopMount(json["service"]["name"].getStr)
            else:
                stopService(json["service"]["name"].getStr)
        of "start":
            if isMount:
                startMount(json["service"]["name"].getStr)
            else:
                startService(json["service"]["name"].getStr)
        of "enable":
            enableService(json["service"]["name"].getStr, isMount)
            if json["service"]["now"].getStr == "true":
                if isMount:
                    startMount(json["service"]["name"].getStr)
                else:
                    startService(json["service"]["name"].getStr)
        of "disable":
            disableService(json["service"]["name"].getStr, isMount)
            if json["service"]["now"].getStr == "true":
                if isMount:
                    stopMount(json["service"]["name"].getStr)
                else:
                    stopService(json["service"]["name"].getStr)


