import ../../common/logging
import osproc
import os
import globalVariables

proc stopService*(serviceName: string) =

    if not dirExists("/run/serviceHandler/"&serviceName):
        info_msg "Service "&serviceName&" is already not running, not trying to stop"
        return

    for i in 0 .. services.len:
        if services[i].serviceName == serviceName:
            terminate(services[i].process)
            discard waitForExit(services[i].process)
            close(services[i].process)
            services.delete(i)
            return

    info_msg "Service "&serviceName&" stopped"

