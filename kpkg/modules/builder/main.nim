#[
This module is the main module for the builder-ng module.
]#
import os
import tables
import sources
import strutils
import ../logger
import ../lockfile
import posix_utils
import ../processes
import ../runparser
import ../isolation
import ../commonPaths
import ../commonTasks



proc cleanUp*() {.noconv.} =
    ## Cleans up.
    debug "builder-ng: clean up"
    removeLockfile()
    quit(0)

proc getArch*(target: string): string =
    var arch: string
        
    if target != "default":
        arch = target.split("-")[0]
    else:
        arch = uname().machine

    
    if arch == "amd64":
        arch = "x86_64" # For compatibility

    debug "arch: '"&arch&"'"

    return arch


proc getKtarget*(target: string, destDir: string): string =
    var kTarget: string

    if target != "default":
        
        if target.split("-").len != 3 and target.split("-").len != 5:
            err("target '"&target&"' invalid", false)
        
        if target.split("-").len == 5:
            kTarget = target
        else:
            kTarget = kpkgTarget(destDir, target)
    else:
        kTarget = kpkgTarget(destDir)

    debug "kpkgTarget: '"&kTarget&"'"

    return kTarget

    

proc preliminaryChecks*(target: string, actualRoot: string) =
    #[
    This function includes the following checks:
        - is root (isAdmin)
        - is kpkg running (isKpkgRunning)
        - does lockfile exist (checkLockfile)
        - set control-c hook (setControlCHook)

    If any of these checks fail, the program will exit.
    ]#
    
    # TODO: have an user mode for this
    if not isAdmin():
        err("you have to be root for this action.", false)
    
    if target != "default" and actualRoot == "default":
        err("internal error: actualRoot needs to be set when target is used (please open a bug report)")

    isKpkgRunning()
    checkLockfile()
    
    setControlCHook(cleanUp)


proc initEnv*(actualPackage: string, kTarget: string) =
    #[
    This function initializes the environment for the build process.

    This includes:
        - Creating the environment
        - Mounting the overlay filesystem

    If any of these checks fail, the program will exit.
    ]#
    debug "builder-ng: initEnv"

    # Create tarball directory if it doesn't exist
    discard existsOrCreateDir("/var/cache")
    discard existsOrCreateDir(kpkgCacheDir)
    discard existsOrCreateDir(kpkgArchivesDir)
    discard existsOrCreateDir(kpkgSourcesDir)
    discard existsOrCreateDir(kpkgSourcesDir&"/"&actualPackage)
    discard existsOrCreateDir(kpkgArchivesDir&"/system")
    discard existsOrCreateDir(kpkgArchivesDir&"/system/"&kTarget)

    # Create required directories
    createDir(kpkgBuildRoot)
    createDir(kpkgSrcDir)

    setFilePermissions(kpkgBuildRoot, {fpUserExec, fpUserRead, fpGroupExec, fpGroupRead,
            fpOthersExec, fpOthersRead})
    setFilePermissions(kpkgSrcDir, {fpOthersWrite, fpOthersRead, fpOthersExec})

    createLockfile()
    debug "builder-ng: initEnv done"
