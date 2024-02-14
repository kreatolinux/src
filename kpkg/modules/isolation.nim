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
import removeInternal
import ../commands/checkcmd
import ../../kreastrap/commonProcs

proc installFromRootInternal(package, root, destdir: string) =
    # Check if package exists and has the right checksum
    check(package, root, true)
    
    let listFiles = root&kpkgInstalledDir&"/"&package&"/list_files"

    for line in lines listFiles:
        let listFilesSplitted = line.split("=")[0].replace("\"", "")
         
        if not (fileExists(root&"/"&listFilesSplitted) or dirExists(root&"/"&listFilesSplitted)):
            debug listFilesSplitted
            err("Internal error occured", false)
        
        discard existsOrCreateDir(destdir)
        
        if fileExists(root&"/"&listFilesSplitted):
            let dirPath = destdir&"/"&relativePath(root&"/"&listFilesSplitted.parentDir(), root)
            
            if not dirExists(dirPath):
                createDirWithPermissionsAndOwnership(root&"/"&listFilesSplitted.parentDir(), dirPath)
            
            copyFileWithPermissionsAndOwnership(root&"/"&listFilesSplitted, destdir&"/"&relativePath(listFilesSplitted, root))
    copyFileWithPermissionsAndOwnership(root&kpkgInstalledDir&"/"&package, destdir&kpkgInstalledDir&"/"&package)

proc installFromRoot*(package, root, destdir: string) =
    # A wrapper for installFromRootInternal that also resolves dependencies.
    for dep in deduplicate(dephandler(@[package], root = root, chkInstalledDirInstead = true, forceInstallAll = true)&package):
        installFromRootInternal(dep, root, destdir)

proc createEnv*(root: string, extraPackages = @[""], path = kpkgEnvPath) =
    # TODO: cross-compilation support
    # TODO: Add ca-certificates
    # TODO: add date to kpkgEnvPath/date, and recreate the rootfs every 3 weeks to keep it up-to-date
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
    let extras = dict.getSectionValue("Extras", "extraPackages").split(" ")&extraPackages

    if not isEmptyOrWhitespace(extras.join("")):
        for i in extras:
            installFromRoot(i, root, kpkgEnvPath)

proc execEnv*(command: string, error = "none", passthrough = false, silentMode = false, path = kpkgEnvPath): int =
    ## Wrapper of execCmdKpkg and Bubblewrap that runs a command in the sandbox.
    # We can use bwrap to chroot.
    if passthrough:
        debug "passthrough true, \""&command&"\""
        return execCmdKpkg("/bin/sh -c \""&command&"\"", error, silentMode = silentMode)
    else:
        debug "passthrough false, \""&command&"\""
        return execCmdKpkg("bwrap --bind "&kpkgEnvPath&" / --bind "&kpkgTempDir1&" "&kpkgTempDir1&" --bind /etc/kpkg/repos /etc/kpkg/repos --bind "&kpkgTempDir2&" "&kpkgTempDir2&" --bind "&kpkgSourcesDir&" "&kpkgSourcesDir&" --dev /dev --proc /proc --perms 1777 --tmpfs /dev/shm --ro-bind /etc/resolv.conf /etc/resolv.conf /bin/sh -c \""&command&"\"", error, silentMode = silentMode)

proc cleanEnv*(packages: seq[string], path = kpkgEnvPath) =
    for package in packages:
        removeInternal(package, path)
