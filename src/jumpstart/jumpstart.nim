import std/net
import os
import osproc
import json
include commonImports


let socket = newSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)

try:
    socket.bindUnix(sockPath)
except CatchableError:
    echo "jumpstart: cannot start, sock already in use (is another instance of jumpstart open?)"
    echo "exiting"
    quit(1)

socket.listen()

echo jumpstartVersion
echo "------------------"

proc ctrlc() {.noconv.} =
    echo "jumpstart: removing socket"
    removeFile(sockPath)
    echo "exiting"
    quit(0)

setControlCHook(ctrlc)

var client: Socket
var address = ""
while true:
    socket.acceptAddr(client, address)
    echo "Client connected from: ", address
    var json = parseJson(client.recvLine())
    echo pretty(json)
    case json["service"]["action"].getStr:
        of "stop":
            echo "stopped service"


