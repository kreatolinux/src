import osproc
import os
import posix
import strutils
import ../commonImports
proc statusDaemon*(process: Process, serviceName: string, command: string,
        options: set[ProcessOption]) =
    ## Reports the status, also runs execPost of the service.
   
    # We have to reapply this as it's an thread local variable, and we are in a multi-threaded proc
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
            let processPost = startProcess(command = command, options = options)
            discard waitForExit(processPost) # We don't care about the exit code of execPost for now
            writeFile(serviceHandlerPath&"/"&serviceName&"/status", "stopped")
        else:
            writeFile(serviceHandlerPath&"/"&serviceName&"/status",
                    "stopped with an exit code "&intToStr(exited))
    except CatchableError:
        writeFile(serviceHandlerPath&"/"&serviceName&"/status", "stopped")
