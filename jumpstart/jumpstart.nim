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

proc getUnitKind(name: string): UnitKind {.gcsafe.} =
  case splitFile(name).ext:
    of ".mount": ukMount
    of ".timer": ukTimer
    else: ukService

var client: Socket
var address = ""
serviceHandlerInit()
while true:
  socket.acceptAddr(client, address)
  var json = parseJson(client.recvLine())
  let unitKind = getUnitKind(getStr(json["service"]["name"], ""))

  case getStr(json["service"]["action"], ""):
    of "stop":
      case unitKind:
        of ukMount:
          stopMount(getStr(json["service"]["name"], ""))
        of ukTimer:
          stopTimer(getStr(json["service"]["name"], ""))
        of ukService:
          stopService(getStr(json["service"]["name"], ""))
    of "start":
      case unitKind:
        of ukMount:
          startMount(getStr(json["service"]["name"], ""))
        of ukTimer:
          startTimer(getStr(json["service"]["name"], ""))
        of ukService:
          startService(getStr(json["service"]["name"], ""))
    of "enable":
      enableUnit(getStr(json["service"]["name"], ""), unitKind)
      if getStr(json["service"]["now"], "") == "true":
        case unitKind:
          of ukMount:
            startMount(getStr(json["service"]["name"], ""))
          of ukTimer:
            startTimer(getStr(json["service"]["name"], ""))
          of ukService:
            startService(getStr(json["service"]["name"], ""))
    of "disable":
      disableUnit(getStr(json["service"]["name"], ""), unitKind)
      if getStr(json["service"]["now"], "") == "true":
        case unitKind:
          of ukMount:
            stopMount(getStr(json["service"]["name"], ""))
          of ukTimer:
            stopTimer(getStr(json["service"]["name"], ""))
          of ukService:
            stopService(getStr(json["service"]["name"], ""))


