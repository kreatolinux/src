# Module for isolating kpkg builds as much as possible
import os
import logger
import sequtils
import strutils
import parsecfg
import processes
import dephandler
import commonTasks
import commonPaths
import ../commands/checkcmd
import ../../kreastrap/commonProcs

proc installFromRootInternal(package, root, destdir: string, removeDestdirOnError = false) = 
    # Check if package exists and has the right checksum
    check(package, root, true)
    
    let listFiles = root&kpkgInstalledDir&"/"&package&"/list_files"

    for line in lines listFiles:
        let listFilesSplitted = line.split("=")[0].replace("\"", "")
        
        if not (fileExists(root&"/"&listFilesSplitted) or dirExists(root&"/"&listFilesSplitted)):
            debug "file: \""&listFilesSplitted&"\", package: \""&package&"\""
            when defined(release):
                info "removing unfinished environment"
                removeDir(destdir)
                err("package \""&package&"\" has a broken symlink/invalid file structure, please reinstall the package", false)
        
        if dirExists(root&"/"&listFilesSplitted) and not symlinkExists(root&"/"&listFilesSplitted):
            let dirPath = destdir&"/"&relativePath(root&"/"&listFilesSplitted, root)
            createDirWithPermissionsAndOwnership(root&"/"&listFilesSplitted, dirPath)
            continue

        discard existsOrCreateDir(destdir)
        
        if fileExists(root&"/"&listFilesSplitted):
            let dirPath = destdir&"/"&relativePath(root&"/"&listFilesSplitted.parentDir(), root)
            
            if not dirExists(dirPath):
                createDirWithPermissionsAndOwnership(root&"/"&listFilesSplitted.parentDir(), dirPath)
            
            copyFileWithPermissionsAndOwnership(root&"/"&listFilesSplitted, destdir&"/"&relativePath(listFilesSplitted, root))
    copyFileWithPermissionsAndOwnership(root&kpkgInstalledDir&"/"&package, destdir&kpkgInstalledDir&"/"&package)

proc installFromRoot*(package, root, destdir: string, removeDestdirOnError = false) =
    # A wrapper for installFromRootInternal that also resolves dependencies.
    for dep in deduplicate(dephandler(@[package], root = root, chkInstalledDirInstead = true, forceInstallAll = true)&package):
        try:
            installFromRootInternal(dep, root, destdir, removeDestdirOnError)
        except:
            if removeDestdirOnError:
                info "removing unfinished environment"
                removeDir(destdir)

            when defined(release):
                err("undefined error, please open an issue", false)
            else:
                raise getCurrentException()

proc createEnvCtrlC() {.noconv.} =
    info "removing unfinished environment"
    removeDir(kpkgEnvPath)
    quit()

proc createEnv*(root: string, path = kpkgEnvPath) =
    # TODO: cross-compilation support
    # TODO: Add ca-certificates
    # TODO: add date to kpkgEnvPath/date, and recreate the rootfs every 3 weeks to keep it up-to-date
    info "initializing sandbox, this might take a while..."
    setControlCHook(createEnvCtrlC)
    initDirectories(kpkgEnvPath, hostCPU, true)
    
    copyFileWithPermissionsAndOwnership(root&"/etc/kreato-release", kpkgEnvPath&"/etc/kreato-release")
    
    let dict = loadConfig(kpkgEnvPath&"/etc/kreato-release")
    
    installFromRoot(dict.getSectionValue("Core", "libc"), root, kpkgEnvPath)
    installFromRoot(dict.getSectionValue("Core", "compiler"), root, kpkgEnvPath)
    
    case dict.getSectionValue("Core", "coreutils"):
        of "gnu":
            # TODO: add other stuff
            installFromRoot("gnu-coreutils", root, kpkgEnvPath)
        of "busybox":
            installFromRoot("busybox", root, kpkgEnvPath)

    installFromRoot(dict.getSectionValue("Core", "tlsLibrary"), root, kpkgEnvPath)
    
    case dict.getSectionValue("Core", "init"):
        of "systemd":
            installFromRoot("systemd", root, kpkgEnvPath)
            installFromRoot("dbus", root, kpkgEnvPath)
        else:
            installFromRoot(dict.getSectionValue("Core", "init"), root, kpkgEnvPath)
            

    installFromRoot(dict.getSectionValue("Core", "init"), root, kpkgEnvPath)
    
    installFromRoot("kreato-fs-essentials", root, kpkgEnvPath)
    installFromRoot("git", root, kpkgEnvPath)
    installFromRoot("kpkg", root, kpkgEnvPath)
    installFromRoot("ca-certificates", root, kpkgEnvPath)

    let extras = dict.getSectionValue("Extras", "extraPackages").split(" ")

    if not isEmptyOrWhitespace(extras.join("")):
        for i in extras:
            installFromRoot(i, root, kpkgEnvPath)
    
    if execCmdKpkg("bwrap --bind "&kpkgEnvPath&" / --bind /etc/resolv.conf /etc/resolv.conf /usr/bin/env update-ca-trust", silentMode = false) != 0:
        removeDir(root)
        err("creating sandbox environment failed", false)

proc umountOverlay*(error = "none", silentMode = false, merged = kpkgMergedPath, upperDir = kpkgOverlayPath&"/upperDir", workDir = kpkgOverlayPath&"/workDir"): int =
    ## Unmounts the overlay.
    discard execCmdKpkg("umount "&kpkgOverlayPath, error, silentMode = silentMode)
    let returnCode = execCmdKpkg("umount "&merged, error, silentMode)
    removeDir(merged)
    removeDir(upperDir)
    removeDir(workDir)
    return returnCode

proc mountOverlay*(upperDir = kpkgOverlayPath&"/upperDir", workDir = kpkgOverlayPath&"/workDir", lowerDir = kpkgEnvPath, merged = kpkgMergedPath, error = "none", silentMode = false): int =
    ## Mounts the overlay.
    ## Directories must have been unmounted.
    try:
        removeDir(kpkgOverlayPath)
    except:
        discard umountOverlay(error, silentMode, merged, upperDir, workDir)
        removeDir(kpkgOverlayPath)

    createDir(kpkgOverlayPath)
    discard execCmdKpkg("mount -t tmpfs tmpfs "&kpkgOverlayPath, error, silentMode = silentMode)

    removeDir(upperDir)
    removeDir(merged)
    removeDir(workDir)
    createDir(upperDir)
    createDir(merged)
    createDir(workDir)
    
    initDirectories(upperDir, hostCPU, true) 

    let cmd = "mount -t overlay overlay -o lowerdir="&lowerDir&",upperdir="&upperDir&",workdir="&workDir&" "&kpkgMergedPath
    debug cmd
    return execCmdKpkg(cmd, error, silentMode = silentMode) 

proc execEnv*(command: string, error = "none", passthrough = false, silentMode = false, path = kpkgMergedPath): int =
    ## Wrapper of execCmdKpkg and Bubblewrap that runs a command in the sandbox.
    # We can use bwrap to chroot.
    if passthrough:
        debug "passthrough true, \""&command&"\""
        return execCmdKpkg("/bin/sh -c \""&command&"\"", error, silentMode = silentMode)
    else:
        debug "passthrough false, \""&command&"\""
        if not dirExists(path):
            err("internal: you have to use mountOverlay() before running execEnv")
        return execCmdKpkg("bwrap --bind "&path&" / --bind "&kpkgTempDir1&" "&kpkgTempDir1&" --bind /etc/kpkg/repos /etc/kpkg/repos --bind "&kpkgTempDir2&" "&kpkgTempDir2&" --bind "&kpkgSourcesDir&" "&kpkgSourcesDir&" --dev /dev --proc /proc --perms 1777 --tmpfs /dev/shm --ro-bind /etc/resolv.conf /etc/resolv.conf /bin/sh -c \""&command&"\"", error, silentMode = silentMode)
