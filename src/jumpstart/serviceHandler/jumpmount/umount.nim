import parsecfg
import osproc
import os
import strutils
import ../../logging
include ../../commonImports

proc stopMount*(mountName: string) =

    if not existsDir("/run/serviceHandler/mounts/"&mountName):
        warn "Mount "&mountName&" is not running, no need to try stopping it"
        return

    var mount: Config

    # Load the configuration.
    try:
        mount = loadConfig(mountPath&"/"&mountName)
    except CatchableError:
        warn "Mount "&mountName&" couldn't be loaded, possibly broken configuration?"
        return

    var cmd = "umount"

    if parseBool(mount.getSectionValue("Mount", "lazyUmount", "no")):
        cmd = cmd&" -l "

    cmd = cmd&" "&mount.getSectionValue("Mount", "To")

    let process = startProcess(command = cmd, options = {poEvalCommand, poUsePath})
    discard waitForExit(process)
    close(process)
