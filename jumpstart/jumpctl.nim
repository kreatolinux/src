import cligen
import std/net
include commonImports
import types
import strutils
import json

let socket = newSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)

## Tool to control Jumpstart.

proc unitName(service: seq[string]): tuple[name: string, kind: UnitKind] =
  ## Convenience proc to check the reported unit name.
  case splitFile(service[0]).ext:
    of "":
      return (name: service[0]&".service", kind: ukService)
    of ".service":
      return (name: service[0], kind: ukService)
    of ".mount":
      return (name: service[0], kind: ukMount)
    of ".timer":
      return (name: service[0], kind: ukTimer)

proc buildMessage(unitName: string, action: string, now: string): string =
  ## Build JSON message for socket communication.
  let message = %* {
    "client": {
      "name": "Jumpstart CLI",
      "version": clCfg.version
    },
    "service": {
      "name": unitName,
      "action": action,
      "now": now
    }
  }
  return $message

proc connectSock(sockPath = sockPath) =
  ## Connect to UNIX socket.
  try:
    socket.connectUnix(sockPath)
  except CatchableError:
    echo "jumpstart: daemon not running"
    quit(1)

proc sendSock(message: string) =
  ## Send information to the UNIX socket.
  if isEmptyOrWhitespace(message):
    echo "jumpstart: please enter service name"
    quit(1)

  socket.send(message&"\c\l")

proc enable(service: seq[string], now = false) =
  ## Enable the service.
  connectSock()

  let unit = unitName(service)

  let nowStr = if now: "true" else: "false"
  sendSock(buildMessage(unit.name, "enable", nowStr))
  echo("jumpstart: enabled unit "&service[0])

proc disable(service: seq[string], now = false) =
  ## Disable the service.
  connectSock()

  let unit = unitName(service)

  let nowStr = if now: "true" else: "false"
  sendSock(buildMessage(unit.name, "disable", nowStr))
  echo("jumpstart: disabled unit "&service[0])

proc start(service: seq[string]) =
  ## Start the service.
  connectSock()

  let unit = unitName(service)

  sendSock(buildMessage(unit.name, "start", "false"))
  echo("jumpstart: started unit "&service[0])

proc stop(service: seq[string]) =
  ## Stop the service.
  connectSock()

  let unit = unitName(service)

  sendSock(buildMessage(unit.name, "stop", "false"))
  echo("jumpstart: stopped unit "&service[0])

proc status(service: seq[string]) =
  ## Check status of the service.

  let unit = unitName(service)

  var status: string
  var statusPath: string

  case unit.kind:
    of ukMount:
      statusPath = serviceHandlerPath&"/mounts/"&unit.name&"/status"
    of ukTimer:
      statusPath = serviceHandlerPath&"/timers/"&unit.name&"/status"
    of ukService:
      statusPath = serviceHandlerPath&"/"&unit.name&"/status"

  try:
    status = readFile(statusPath)
  except CatchableError:
    status = "stopped"

  echo "jumpstart: unit is reporting status as '"&status&"'"

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
