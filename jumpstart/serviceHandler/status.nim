import osproc
import os
import posix
import strutils
import ../commonImports
import ../exec
import ../../common/logging

proc statusDaemon*(process: Process, serviceName: string, command: string,
        options: set[ProcessOption]) =
  ## Reports the status, also runs execPost of the service.

  # We have to reapply this as it's a thread local variable, and we are in a multi-threaded proc
  if isEmptyOrWhitespace(serviceHandlerPath):
    if getuid() == 0:
      serviceHandlerPath = "/run/serviceHandler"
    else:
      serviceHandlerPath = getEnv("HOME")&"/.local/share/serviceHandler"

  if not fileExists(serviceHandlerPath&"/"&serviceName&"/status"):
    writeFile(serviceHandlerPath&"/"&serviceName&"/status", "running")

  try:
    let exited = waitForExit(process)
    if exited == 0:
      if command.len > 0:
        let processPost = execDirect(command, options = options)
        let postExitCode = waitForExit(processPost)
        if postExitCode != 0:
          warn serviceName & " execPost failed with exit code " & $postExitCode
      writeFile(serviceHandlerPath&"/"&serviceName&"/status", "stopped")
    else:
      writeFile(serviceHandlerPath&"/"&serviceName&"/status",
              "stopped with an exit code "&intToStr(exited))
  except CatchableError as e:
    warn serviceName & " status daemon error: " & e.msg
    writeFile(serviceHandlerPath&"/"&serviceName&"/status", "stopped")
