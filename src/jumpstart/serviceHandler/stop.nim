import ../logging
import os

proc stopService*(serviceName: string) =
    ## Convenience proc, actual stopping is handled in statusDaemon
    if dirExists("/run/serviceHandler/"&serviceName):
        writeFile("/run/serviceHandler/"&serviceName&"/stopFile", "")
        info_msg "Service "&serviceName&" stopped"
    else:
        info_msg "Service "&serviceName&" is already not running, not trying to stop"
