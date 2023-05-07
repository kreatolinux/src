import osproc
import os

proc statusDaemon*(process: Process, serviceName: string) =
    ## The status daemon, checks constantly for the status of the service.
    ## Also stops service if requested.
    while true:
        # Probably a bad way to do this but it should work for now
        
        if fileExists("/run/serviceHandler/"&serviceName&"/stopFile"):
            terminate(process)
            discard waitForExit(process)
            close(process)
            removeDir("/run/serviceHandler/"&serviceName)
            return
        
        if running(process):
            writeFile("/run/serviceHandler/"&serviceName&"/status", """running""")
        else:
            writeFile("/run/serviceHandler/"&serviceName&"/status", """stopped""")
        

        
        sleep(5)
