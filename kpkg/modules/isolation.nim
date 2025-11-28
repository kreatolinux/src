# Module for isolating kpkg builds as much as possible
import std/os
import logger
import sqlite
import std/times
import processes
import dephandler
import commonPaths
import commonTasks
import std/sequtils
import std/strutils
import std/parsecfg
import ../modules/config
import ../commands/checkcmd
import ../../kreastrap/commonProcs

proc execEnv*(command: string, error = "none", passthrough = false, silentMode = false, path = kpkgMergedPath, remount = false): int =
    ## Wrapper of execCmdKpkg and Bubblewrap that runs a command in the sandbox.
    # We can use bwrap to chroot.
    const localeEnvPrefix = "LC_ALL=C.UTF-8 LC_CTYPE=C.UTF-8 LANG=C.UTF-8 "
    if passthrough:
        debug "passthrough true, \""&command&"\""
        return execCmdKpkg(localeEnvPrefix&"/bin/sh -c \""&command&"\"", error, silentMode = silentMode)
    else:
        debug "passthrough false, \""&command&"\""
        if not dirExists(path):
            err("internal: you have to use mountOverlay() before running execEnv")
        
        if remount:
            discard execCmdKpkg("mount -o remount "&path, silentMode = silentMode)

        # Create dirs so that bwrap doesn't complain
        createDir(kpkgTempDir1)
        createDir(kpkgTempDir2)

        return execCmdKpkg(localeEnvPrefix&"bwrap --bind "&path&" / --bind "&kpkgTempDir1&" "&kpkgTempDir1&" --bind /etc/kpkg/repos /etc/kpkg/repos --bind "&kpkgTempDir2&" "&kpkgTempDir2&" --bind "&kpkgSourcesDir&" "&kpkgSourcesDir&" --dev /dev --proc /proc --perms 1777 --tmpfs /dev/shm --ro-bind /etc/resolv.conf /etc/resolv.conf /bin/sh -c \""&command&"\"", error, silentMode = silentMode)

proc runPostInstall*(package: string, rootPath = kpkgMergedPath) =
    ## Runs postinstall scripts for a package in the provided environment root.
    ## Defaults to the merged overlay, but can be overridden (e.g. createEnv).
    debug "runPostInstall ran, package: '"&package&"', root: '"&rootPath&"'"
    let repo = findPkgRepo(package)

    if isEmptyOrWhitespace(repo):
        return # bail early if no repo is found
    
    var existsPkgPostinstall = execEnv(
            ". "&repo&"/"&package&"/run"&" && command -v postinstall_"&replace(
                    package, '-', '_'), remount = true, silentMode = true, path = rootPath)
    var existsPostinstall = execEnv(
            ". "&repo&"/"&package&"/run"&" && command -v postinstall", remount = true, silentMode = true, path = rootPath)

    if existsPkgPostinstall == 0:
        if execEnv(". "&repo&"/"&package&"/run"&" && postinstall_"&replace(
                package, '-', '_'), remount = true, silentMode = true, path = rootPath) != 0:
                err("postinstall failed on sandbox")
    elif existsPostinstall == 0:
        if execEnv(". "&repo&"/"&package&"/run"&" && postinstall", remount = true, silentMode = true, path = rootPath) != 0:
                err("postinstall failed on sandbox")


proc installFromRootInternal(package, root, destdir: string, removeDestdirOnError = false, ignorePostInstall = false) = 
    
    debug "installFromRootInternal: package: \""&package&"\", root: \""&root&"\", destdir: \""&destdir&"\", removeDestdirOnError: \""&($removeDestdirOnError)&"\", ignorePostInstall: \""&($ignorePostInstall)&"\""

    # Check if package exists and has the right checksum
    check(package, root, true)
    
    let listFiles = getListFiles(package, root)

    for line in listFiles:
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
    newPackageFromRoot(root, package, destdir)
    
    if ignorePostInstall:
        return

    runPostInstall(package, destdir)



proc installFromRoot*(package, root, destdir: string, removeDestdirOnError = false, ignorePostInstall = false): seq[string] =
    # A wrapper for installFromRootInternal that also resolves dependencies.
    if isEmptyOrWhitespace(package):
        return

    let depsUsed = deduplicate(dephandler(@[package], root = root, chkInstalledDirInstead = true, forceInstallAll = true)&package)
    for dep in depsUsed:
        
        if isEmptyOrWhitespace(dep):
            continue

        try:
            installFromRootInternal(dep, root, destdir, removeDestdirOnError, ignorePostInstall)
        except:
            if removeDestdirOnError:
                info "removing unfinished environment"
                removeDir(destdir)

            when defined(release):
                err("undefined error, please open an issue", false)
            else:
                raise getCurrentException()
    return depsUsed

proc createEnvCtrlC() {.noconv.} =
    info "removing unfinished environment"
    removeDir(kpkgEnvPath)
    quit()

proc createEnv*(root: string, ignorePostInstall = false) =
    # TODO: cross-compilation support
    info "initializing sandbox, this might take a while..."
    setControlCHook(createEnvCtrlC)
    initDirectories(kpkgEnvPath, hostCPU, true)
    
    copyFileWithPermissionsAndOwnership(root&"/etc/kreato-release", kpkgEnvPath&"/etc/kreato-release")
    
    var depsTotal: seq[string]

    let dict = loadConfig(kpkgEnvPath&"/etc/kreato-release")
    
    depsTotal.add installFromRoot(dict.getSectionValue("Core", "libc"), root, kpkgEnvPath, ignorePostInstall = true)
    let compiler = dict.getSectionValue("Core", "compiler")
    if compiler == "clang":
        depsTotal.add installFromRoot("llvm", root, kpkgEnvPath, ignorePostInstall = true)
    else:
        depsTotal.add installFromRoot(compiler, root, kpkgEnvPath, ignorePostInstall = true)
    
    try:
        setDefaultCC(kpkgEnvPath, compiler)
    except:
        removeDir(root)
        when defined(release):
            err("setting default compiler in the environment failed", false)
        else:
            raise getCurrentException()

    case dict.getSectionValue("Core", "coreutils"):
        of "gnu":
            for i in ["gnu-coreutils", "pigz", "xz-utils", "bash", "gsed", "bzip2", "patch", "diffutils", "findutils", "util-linux", "bc", "cpio", "which"]:
                depsTotal.add installFromRoot(i, root, kpkgEnvPath, ignorePostInstall = true)
            #installFromRoot("gnu-core", root, kpkgEnvPath, ignorePostInstall = true)
        of "busybox":
            depsTotal.add installFromRoot("busybox", root, kpkgEnvPath, ignorePostInstall = true)

    depsTotal.add installFromRoot(dict.getSectionValue("Core", "tlsLibrary"), root, kpkgEnvPath, ignorePostInstall = true)
    
    case dict.getSectionValue("Core", "init"):
        of "systemd":
            depsTotal.add installFromRoot("systemd", root, kpkgEnvPath, ignorePostInstall = true)
            depsTotal.add installFromRoot("dbus", root, kpkgEnvPath, ignorePostInstall = true)
        else:
            depsTotal.add installFromRoot(dict.getSectionValue("Core", "init"), root, kpkgEnvPath, ignorePostInstall = true)
            
    depsTotal.add installFromRoot(dict.getSectionValue("Core", "init"), root, kpkgEnvPath, ignorePostInstall = true)
    
    for i in "kreato-fs-essentials git kpkg ca-certificates python python-pip gmake".split(" "):
        depsTotal.add installFromRoot(i, root, kpkgEnvPath, ignorePostInstall = true)
    

    #let extras = dict.getSectionValue("Extras", "extraPackages").split(" ")

    #if not isEmptyOrWhitespace(extras.join("")):
    #    for i in extras:
    #        installFromRoot(i, root, kpkgEnvPath)
    
    if execCmdKpkg("bwrap --bind "&kpkgEnvPath&" / --bind /etc/resolv.conf /etc/resolv.conf /usr/bin/env update-ca-trust", silentMode = false) != 0:
        removeDir(root)
        err("creating sandbox environment failed", false)
    
    writeFile(kpkgEnvPath&"/envDateBuilt", now().format("yyyy-MM-dd"))

    if ignorePostInstall == false:
        for dep in deduplicate(depsTotal):
            if isEmptyOrWhitespace(dep):
                continue
            runPostInstall(dep, kpkgEnvPath)

proc umountOverlay*(error = "none", silentMode = false, merged = kpkgMergedPath, upperDir = kpkgOverlayPath&"/upperDir", workDir = kpkgOverlayPath&"/workDir"): int =
    ## Unmounts the overlay.
    closeDb()
    let returnCode = execCmdKpkg("umount "&merged, error, silentMode)
    discard execCmdKpkg("umount "&kpkgOverlayPath, error, silentMode = silentMode)
    removeDir(merged)
    removeDir(upperDir)
    removeDir(workDir)
    return returnCode

proc prepareOverlayDirs*(upperDir = kpkgOverlayPath&"/upperDir", workDir = kpkgOverlayPath&"/workDir", merged = kpkgMergedPath, error = "none", silentMode = false): int =
    ## Prepares the overlay directories by mounting tmpfs and creating directory structure
    ## without mounting the overlayfs itself. This allows installing build dependencies
    ## before the overlay is mounted.
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
    return 0

proc mountOverlayFilesystem*(upperDir = kpkgOverlayPath&"/upperDir", workDir = kpkgOverlayPath&"/workDir", lowerDir = kpkgEnvPath, merged = kpkgMergedPath, error = "none", silentMode = false): int =
    ## Mounts the overlayfs. Should be called after prepareOverlayDirs() and after
    ## installing build dependencies to upperDir.
    let cmd = "mount -t overlay overlay -o lowerdir="&lowerDir&",upperdir="&upperDir&",workdir="&workDir&" "&merged
    debug cmd
    return execCmdKpkg(cmd, error, silentMode = silentMode)

proc mountOverlay*(upperDir = kpkgOverlayPath&"/upperDir", workDir = kpkgOverlayPath&"/workDir", lowerDir = kpkgEnvPath, merged = kpkgMergedPath, error = "none", silentMode = false): int =
    ## Mounts the overlay in one step (prepare directories and mount overlayfs).
    ## For build processes that need to install dependencies before mounting,
    ## use prepareOverlayDirs() and mountOverlayFilesystem() separately.
    discard prepareOverlayDirs(upperDir, workDir, merged, error, silentMode)
    return mountOverlayFilesystem(upperDir, workDir, lowerDir, merged, error, silentMode) 

