import cligen
import std/net
include commonImports
import strutils
import unitname
import json

let socket = newSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)

## Tool to control Jumpstart.

proc unitName(service: seq[string]): string =
  ## Normalize names to the unified .kg definition name. Legacy suffixes are
  ## accepted for compatibility but are not sent to the daemon.
  if service.len == 0 or isEmptyOrWhitespace(service[0]):
    echo "jumpstart: please enter unit name"
    quit(1)
  result = normalizeUnitName(service[0])

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
  sendSock(buildMessage(unit, "enable", nowStr))
  echo("jumpstart: enabled unit "&service[0])

proc disable(service: seq[string], now = false) =
  ## Disable the service.
  connectSock()

  let unit = unitName(service)

  let nowStr = if now: "true" else: "false"
  sendSock(buildMessage(unit, "disable", nowStr))
  echo("jumpstart: disabled unit "&service[0])

proc start(service: seq[string]) =
  ## Start the service.
  connectSock()

  let unit = unitName(service)

  sendSock(buildMessage(unit, "start", "false"))
  echo("jumpstart: started unit "&service[0])

proc stop(service: seq[string]) =
  ## Stop the service.
  connectSock()

  let unit = unitName(service)

  sendSock(buildMessage(unit, "stop", "false"))
  echo("jumpstart: stopped unit "&service[0])

proc status(service: seq[string]) =
  ## Check status of the service.

  let unit = unitName(service)

  var status = "stopped"
  # Running state already records the unit kind in its directory. Checking all
  # three locations also makes status work for bare .kg unit names.
  for statusPath in [
    serviceHandlerPath&"/"&unit&"/status",
    serviceHandlerPath&"/mounts/"&unit&"/status",
    serviceHandlerPath&"/timers/"&unit&"/status"
  ]:
    try:
      if fileExists(statusPath):
        status = readFile(statusPath)
        break
    except CatchableError:
      discard

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
