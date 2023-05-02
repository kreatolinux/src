import std/net
import os
import json
import terminal
import serviceHandler/main
include commonImports


proc debug(message: string) =
    when not defined(release):
        styledEcho "[", styleBlinkRapid, styleBright, fgYellow, " DEBUG ",
                resetStyle, "] "&message

proc info_msg(message: string) =
    styledEcho "[", styleBright, fgBlue, " INFO ", resetStyle, "] "&message

proc ok(message: string) =
    styledEcho "[", styleBright, fgGreen, " OK ", resetStyle, "] "&message

proc warn(message: string) =
    styledEcho "[", styleBright, fgYellow, " WARN ", resetStyle, "] "&message

proc error(message: string) =
    styledEcho "[", styleBright, fgRed, " ERROR ", resetStyle, "] "&message
    quit(1)

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
while true:
    socket.acceptAddr(client, address)
    var json = parseJson(client.recvLine())
    serviceHandlerInit()
    #echo pretty(json)
    case json["service"]["action"].getStr:
        of "stop":
            stopService(json["service"]["name"].getStr)
            ok "stopped service "&json["service"]["name"].getStr
        of "start":
            startService(json["service"]["name"].getStr)
            ok "started service "&json["service"]["name"].getStr
        of "enable":
            enableService(json["service"]["name"].getStr)
            ok "enabled service "&json["service"]["name"].getStr
            if json["service"]["now"].getStr == "true":
                startService(json["service"]["name"].getStr)
                ok "started service "&json["service"]["name"].getStr
        of "disable":
            disableService(json["service"]["name"].getStr)
            ok "disabled service "&json["service"]["name"].getStr
            if json["service"]["now"].getStr == "true":
                stopService(json["service"]["name"].getStr)
                ok "stopped service "&json["service"]["name"].getStr



