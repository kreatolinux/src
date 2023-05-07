import osproc
import os
import strutils
proc statusDaemon*(process: Process, serviceName: string) =

    if not fileExists("/run/serviceHandler/"&serviceName&"/status"):
        writeFile("/run/serviceHandler/"&serviceName&"/status", "running")

    try:
        let exited = waitForExit(process)
        if exited == 0:
            writeFile("/run/serviceHandler/"&serviceName&"/status", "stopped")
        else:
            writeFile("/run/serviceHandler/"&serviceName&"/status",
                    "stopped with an exit code "&intToStr(exited))
    except CatchableError:
        writeFile("/run/serviceHandler/"&serviceName&"/status", "stopped")
