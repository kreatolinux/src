import parsecfg
import ../../logging
include ../../commonImports

proc startMount*(mountName: string) =
    ## Main function for mounts.
    
    var mount: Config
    
    # Load the configuration.
    try:
        mount = loadConfig(mountPath&"/"&mountName)
    except CatchableError:
        warn "Mount "&mountName&" couldn't be started, possibly broken configuration?"
        return
    
    ok "Mounted "&mountName