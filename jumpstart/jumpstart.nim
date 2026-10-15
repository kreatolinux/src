import std/net
import json
include serviceHandler/main

var userMode = false

if paramCount() > 1:
  error "too many arguments"
elif paramCount() == 1:
  if paramStr(1) == "--user":
    userMode = true
  else:
    error "unknown argument"

if getCurrentProcessId() != 1 and not userMode:
  error "jumpstart needs to be ran as PID 1 (init) to function correctly"

if userMode:
  info "running in user mode"
else:
  info "running in PID1 mode"
  ## Initialize the entire system, such as mounting /proc etc.
  initSystem()

let socket = newSocket(domain = AF_UNIX, sockType = SOCK_STREAM,
        protocol = IPPROTO_IP)

try:
  socket.bindUnix(sockPath)
except CatchableError:
  error "cannot start, sock already in use (is another instance of jumpstart open?)"

socket.listen()

info "Initializing "&jumpstartVersion


proc ctrlc() {.noconv.} =
  info "removing socket"
  removeFile(sockPath)
  removeDir(serviceHandlerPath)
  info "exiting"
  quit(0)

setControlCHook(ctrlc)

var client: Socket
var address = ""
serviceHandlerInit()
while true:
  socket.acceptAddr(client, address)
  var json = parseJson(client.recvLine())
  let unitName = getStr(json["service"]["name"], "")

  case getStr(json["service"]["action"], ""):
    of "stop":
      stopRequestedUnit(unitName)
    of "start":
      startRequestedUnit(unitName)
    of "enable":
      enableUnit(unitName)
      if getStr(json["service"]["now"], "") == "true":
        startRequestedUnit(unitName)
    of "disable":
      disableUnit(unitName)
      if getStr(json["service"]["now"], "") == "true":
        stopRequestedUnit(unitName)
    else:
      warn "Unknown unit action"
