# Jumpstart configuration
# Here, you can find the usual stuff.
import os

proc getuid(): cint {.importc, header: "<unistd.h>", sideEffect, raises: [],
                     tags: [], forbids: [].}

# Jumpstart version
const jumpstartVersion* {.used.} = "jumpstart v1.1.0"

# Jumpstart paths
var sockPath* {.threadvar.}: string
var configPath* {.threadvar.}: string # Config path for .kg unit files
var serviceHandlerPath* {.threadvar.}: string

if getuid() != 0:
  # User mode
  sockPath = getEnv("HOME")&"/.local/share/jumpstart.sock"
  configPath = getEnv("HOME")&"/.config/jumpstart"
  serviceHandlerPath = getEnv("HOME")&"/.local/share/serviceHandler"
else:
  sockPath = "/run/jumpstart.sock"
  configPath = "/etc/jumpstart"
  serviceHandlerPath = "/run/serviceHandler"
