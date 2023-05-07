import std/net
import json
include serviceHandler/main
import logging

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
    case json["service"]["action"].getStr:
        of "stop":
            stopService(json["service"]["name"].getStr)
        of "start":
            startService(json["service"]["name"].getStr)
        of "enable":
            enableService(json["service"]["name"].getStr)
            if json["service"]["now"].getStr == "true":
                startService(json["service"]["name"].getStr)
        of "disable":
            disableService(json["service"]["name"].getStr)
            if json["service"]["now"].getStr == "true":
                stopService(json["service"]["name"].getStr)



