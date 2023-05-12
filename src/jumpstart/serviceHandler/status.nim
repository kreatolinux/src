import osproc
import os
import strutils
proc statusDaemon*(process: Process, serviceName: string, command: string,  options: set[ProcessOption]) =
    ## Reports the status, also runs execPost of the service.
    if not fileExists("/run/serviceHandler/"&serviceName&"/status"):
        writeFile("/run/serviceHandler/"&serviceName&"/status", "running")

    try:
        let exited = waitForExit(process)
        if exited == 0:
            let processPost = startProcess(command=command, options=options)
            discard waitForExit(processPost) # We don't care about the exit code of execPost for now
            writeFile("/run/serviceHandler/"&serviceName&"/status", "stopped")
        else:
            writeFile("/run/serviceHandler/"&serviceName&"/status",
                    "stopped with an exit code "&intToStr(exited))
    except CatchableError:
        writeFile("/run/serviceHandler/"&serviceName&"/status", "stopped")
