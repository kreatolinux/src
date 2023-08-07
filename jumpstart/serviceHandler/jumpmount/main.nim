import parsecfg
import ../../../common/logging
import os
import strutils
import osproc
import fusion/filepermissions
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

    # Just a sanity check
    if mount.getSectionValue("Info", "Type") != "mount":
        warn "Mount "&mountName&" has an incorrect type"
        return

    if not dirExists(mount.getSectionValue("Mount", "To")):
        createDir(mount.getSectionValue("Mount", "To"))
        chmod(mount.getSectionValue("Mount", "To"), parseInt(
                mount.getSectionValue("Mount", "Chmod", "0755")))

    var cmd = "mount"

    if mount.getSectionValue("Mount", "Type") != "":
        cmd = cmd&" -t "&mount.getSectionValue("Mount", "Type")

    cmd = cmd&" "&mount.getSectionValue("Mount",
            "From")&" "&mount.getSectionValue("Mount", "To")

    cmd = cmd&mount.getSectionValue("Mount", "extraArgs")

    let process = startProcess(command = cmd, options = {poEvalCommand, poUsePath})

    if mount.getSectionValue("Mount", "Timeout") != "":
        sleep(parseInt(mount.getSectionValue("Mount", "Timeout")))
        if running(process):
            terminate(process)
            discard waitForExit(process)
            close(process)
            warn "Mounting "&mountName&" failed, timeout reached"
            return
    elif waitForExit(process) != 0:
        warn "Mounting "&mountName&" failed, possibly broken configuration"
        return

    close(process)
    createDir("/run/serviceHandler/mounts/"&mountName)
    writeFile("/run/serviceHandler/mounts/"&mountName&"/status", "mounted")
    ok "Mounted "&mountName
