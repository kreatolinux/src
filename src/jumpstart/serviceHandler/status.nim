import osproc
import os
import strutils

proc statusDaemon*(process: Process, serviceName: string) =

    if not fileExists("/run/serviceHandler/"&serviceName&"/status"):
        writeFile("/run/serviceHandler/"&serviceName&"/status", "running")

    let exited = waitForExit(process)

    if exited == 0:
        writeFile("/run/serviceHandler/"&serviceName&"/status", "stopped")
    else:
        writeFile("/run/serviceHandler/"&serviceName&"/status",
                "stopped with an exit code "&intToStr(exited))

    while true:
        if fileExists("/run/serviceHandler/"&serviceName&"/stopFile"):
            terminate(process)
            discard waitForExit(process)
            close(process)
            removeDir("/run/serviceHandler/"&serviceName)
            return
