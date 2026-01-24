# Jumpstart configuration
# Here, you can find the usual stuff.
import os

proc getuid(): cint {.importc, header: "<unistd.h>", sideEffect, raises: [],
                     tags: [], forbids: [].}

# Jumpstart version
const jumpstartVersion = "jumpstart v1.1.0"

# Jumpstart paths
var sockPath {.threadvar.}: string
var servicePath {.threadvar.}: string
var mountPath {.threadvar.}: string
var timerPath {.threadvar.}: string
var serviceHandlerPath* {.threadvar.}: string

if getuid() != 0:
  # User mode
  sockPath = getEnv("HOME")&"/.local/share/jumpstart.sock"
  servicePath = getEnv("HOME")&"/.config/jumpstart/services"
  mountPath = getEnv("HOME")&"/.config/jumpstart/mounts"
  timerPath = getEnv("HOME")&"/.config/jumpstart/timers"
  serviceHandlerPath = getEnv("HOME")&"/.local/share/serviceHandler"
else:
  sockPath = "/run/jumpstart.sock"
  servicePath = "/etc/jumpstart/services"
  mountPath = "/etc/jumpstart/mounts"
  timerPath = "/etc/jumpstart/timers"
  serviceHandlerPath = "/run/serviceHandler"
