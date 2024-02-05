import os
import posix
import osproc
import strutils
import sequtils
import parsecfg
import ../modules/config
import ../modules/logger
import ../modules/lockfile
import ../modules/checksums
import ../modules/runparser
import ../modules/processes
import ../modules/downloader
import ../modules/dephandler
import ../modules/libarchive
import ../modules/commonTasks
import ../modules/commonPaths
import ../modules/removeInternal

setControlCHook(ctrlc)

proc copyFileWithPermissionsAndOwnership(source, dest: string, options = {cfSymlinkFollow}) =
    ## Copies a file with both permissions and ownership.
    var statVar: Stat
    assert stat(source, statVar) == 0
    copyFileWithPermissions(source, dest)
    #debug "copyFileWithPermissions successful, setting chown"
    assert posix.chown(dest, statVar.st_uid, statVar.st_gid) == 0

proc createDirWithPermissionsAndOwnership(source, dest: string, followSymlinks = true) =
    var statVar: Stat
    assert stat(source, statVar) == 0
    createDir(dest)
    #debug "createDir successful, setting chown and chmod"
    assert posix.chown(dest, statVar.st_uid, statVar.st_gid) == 0
    #debug "chown successful, setting permissions"
    setFilePermissions(dest, getFilePermissions(source), followSymlinks)


proc installPkg*(repo: string, package: string, root: string, runf = runFile(
        isParsed: false), manualInstallList: seq[string], isUpgrade = false, arch = hostCPU, kTarget = kpkgTarget(root), ignorePostInstall = false) =
    ## Installs a package.

    var pkg: runFile
    
    try:
        if runf.isParsed:
            pkg = runf
        else:
            pkg = parseRunfile(repo&"/"&package)
    except CatchableError:
        err("Unknown error while trying to parse package on repository, possibly broken repo?")

    debug "installPkg ran, repo: '"&repo&"', package: '"&package&"', root: '"&root&"', manualInstallList: '"&manualInstallList.join(" ")&"'"

    if isUpgrade:
        let existsPkgPreUpgrade = execCmdEx(". "&repo&"/"&package&"/run"&" && command -v preupgrade_"&replace(package, '-', '_')).exitCode
        let existsPreUpgrade = execCmdEx(". "&repo&"/"&package&"/run"&" && command -v preupgrade").exitCode

        if existsPkgPreUpgrade == 0:
            if execCmdKpkg(". "&repo&"/"&package&"/run"&" && preupgrade_"&replace(
                    package, '-', '_')) != 0:
                err("preupgrade failed")
            
        if existsPreUpgrade == 0:
            if execCmdKpkg(". "&repo&"/"&package&"/run"&" && preupgrade") != 0:
                err("preupgrade failed")
    
    let isGroup = pkg.isGroup

    for i in pkg.conflicts:
        if dirExists(root&kpkgInstalledDir&"/"&i):
            err(i&" conflicts with "&package)
    
    removeDir("/tmp/kpkg/reinstall/"&package&"-old")
    createDir("/tmp")
    createDir("/tmp/kpkg")

    var tarball: string

    if not isGroup:
        tarball = kpkgArchivesDir&"/system/"&kTarget&"/kpkg-tarball-"&package&"-"&pkg.versionString&".tar.gz"
        
    setCurrentDir(kpkgArchivesDir)
    
    for i in pkg.replaces:
        if symlinkExists(root&kpkgInstalledDir&"/"&i):
            removeFile(root&kpkgInstalledDir&"/"&i)
        elif dirExists(root&kpkgInstalledDir&"/"&i):
            if arch != hostCPU:
                removeInternal(i, root, initCheck = false)
            else:
                removeInternal(i, root)
        createSymlink(package, root&kpkgInstalledDir&"/"&i)

    if dirExists(root&kpkgInstalledDir&"/"&package) and
            not symlinkExists(root&kpkgInstalledDir&"/"&package) and not isGroup:

        info "package already installed, reinstalling"
        if not fileExists(root&kpkgInstalledDir&"/"&package&"/list_files"):
            warn "'"&package&"' seems to be not installed correctly"
            warn "removing '"&package&"' from database, but there may be some leftovers"
            warn "please open an issue at https://github.com/kreatolinux/src with how this happened"
            removeDir(root&kpkgInstalledDir&"/"&package)
        else:
            if arch != hostCPU:
                removeInternal(package, root, ignoreReplaces = true, noRunfile = true, initCheck = false)
            else:
                removeInternal(package, root, ignoreReplaces = true, noRunfile = true)

    discard existsOrCreateDir(root&"/var/cache")
    discard existsOrCreateDir(root&kpkgCacheDir)
    discard existsOrCreateDir(root&kpkgInstalledDir)
    removeDir(root&kpkgInstalledDir&"/"&package)
    copyDir(repo&"/"&package, root&kpkgInstalledDir&"/"&package)
    
    if not isGroup:
        var extractTarball: seq[string]
        let kpkgInstallTemp = kpkgTempDir1&"/install-"&package
        if dirExists(kpkgInstallTemp):
            removeDir(kpkgInstallTemp)
        
        createDir(kpkgInstallTemp)
        setCurrentDir(kpkgInstallTemp)
        try:
          extractTarball = extract(tarball, kpkgInstallTemp, pkg.backup)
        except Exception:
            removeDir(root&kpkgInstalledDir&"/"&package)
            when defined(release):
                err("extracting the tarball failed for "&package)
            else:
                raise getCurrentException()
        
        var dict = loadConfig(kpkgInstallTemp&"/pkgsums.ini")
            
        # Checking loop
        for file in extractTarball:
            if "pkgsums.ini" == lastPathPart(file): continue
            debug kpkgInstallTemp&"/"&relativePath(file, kpkgInstallTemp)
            let value = dict.getSectionValue("", relativePath(file, kpkgInstallTemp))
            let doesFileExist = (fileExists(kpkgInstallTemp&"/"&file) and not symlinkExists(kpkgInstallTemp&"/"&file))

            if isEmptyOrWhitespace(value) and not doesFileExist:
                continue
                
            if isEmptyOrWhitespace(value) and doesFileExist:
                debug file
                err("package sums invalid")

            if getSum(kpkgInstallTemp&"/"&file, "b2") != value:
                err("sum for file '"&file&"' invalid")
            
        # Installation loop 
        for file in extractTarball:
            if "pkgsums.ini" == lastPathPart(file):
                moveFile(kpkgInstallTemp&"/"&file, kpkgInstalledDir&"/"&package&"/list_files")
            let doesFileExist = fileExists(kpkgInstallTemp&"/"&file)
            if doesFileExist:
                if not dirExists(root&"/"&file.parentDir()):
                    createDirWithPermissionsAndOwnership(kpkgInstallTemp&"/"&file.parentDir(), root&"/"&file.parentDir())
                copyFileWithPermissionsAndOwnership(kpkgInstallTemp&"/"&file, root&"/"&file)
            elif dirExists(kpkgInstallTemp&"/"&file) and (not dirExists(root&"/"&file)):
                createDirWithPermissionsAndOwnership(kpkgInstallTemp&"/"&file, root&"/"&file)

    # Run ldconfig afterwards for any new libraries
    discard execProcess("ldconfig")
    
    when defined(release):
        removeDir(kpkgTempDir1)
        removeDir(kpkgTempDir2)

    if package in manualInstallList:
      info "Setting as manually installed"
      writeFile(root&kpkgInstalledDir&"/"&package&"/manualInstall", "")

    var existsPkgPostinstall = execCmdEx(
            ". "&repo&"/"&package&"/run"&" && command -v postinstall_"&replace(
                    package, '-', '_')).exitCode
    var existsPostinstall = execCmdEx(
            ". "&repo&"/"&package&"/run"&" && command -v postinstall").exitCode

    if existsPkgPostinstall == 0:
        if execCmdKpkg(". "&repo&"/"&package&"/run"&" && postinstall_"&replace(
                package, '-', '_')) != 0:
            if ignorePostInstall:
                warn "postinstall failed"
            else:
                err("postinstall failed")
    elif existsPostinstall == 0:
        if execCmdKpkg(". "&repo&"/"&package&"/run"&" && postinstall") != 0:
            if ignorePostInstall:
                warn "postinstall failed"
            else:
                err("postinstall failed")

    
    if isUpgrade:
        var existsPkgPostUpgrade = execCmdEx(". "&repo&"/"&package&"/run"&" && command -v postupgrade_"&replace(package, '-', '_')).exitCode
        var existsPostUpgrade = execCmdEx(". "&repo&"/"&package&"/run"&" && command -v postupgrade").exitCode
        
        if existsPkgPostUpgrade == 0:
            if execCmdKpkg(". "&repo&"/"&package&"/run"&" && postupgrade_"&replace(package, '-', '_')) != 0:
                err("postupgrade failed")
        
        if existsPostUpgrade == 0:
            if execCmdKpkg(". "&repo&"/"&package&"/run"&" && postupgrade") != 0:
                err("postupgrade failed")

    for i in pkg.optdeps:
        info(i)

proc down_bin(package: string, binrepos: seq[string], root: string,
        offline: bool, forceDownload = false, ignoreDownloadErrors = false, kTarget = kpkgTarget(root)) =
    ## Downloads binaries.
    
    discard existsOrCreateDir("/var/")
    discard existsOrCreateDir("/var/cache")
    discard existsOrCreateDir("/var/cache/kpkg")
    discard existsOrCreateDir(kpkgArchivesDir)
    discard existsOrCreateDir(kpkgArchivesDir&"/system")
    discard existsOrCreateDir(kpkgArchivesDir&"/system/"&kTarget)

    setCurrentDir(kpkgArchivesDir)
    var downSuccess: bool

    var binreposFinal = binrepos
    
    var override: Config
    
    if fileExists("/etc/kpkg/override/"&package&".conf"):
        override = loadConfig("/etc/kpkg/override/"&package&".conf")
    else:
        override = newConfig() # So we don't get storage access errors
    
    let binreposOverride = override.getSectionValue("Mirror", "binaryMirrors")

    if not isEmptyOrWhitespace(binreposOverride):
        binreposFinal = binreposOverride.split(" ")

    for binrepo in binreposFinal:
        var repo: string

        repo = findPkgRepo(package)
        var pkg: runFile

        try:
            pkg = parseRunfile(repo&"/"&package)
        except CatchableError:
            err("Unknown error while trying to parse package on repository, possibly broken repo?")

        if pkg.isGroup:
            return

        let tarball = "kpkg-tarball-"&package&"-"&pkg.versionString&".tar.gz"
        let chksum = tarball&".sum"

        if fileExists(kpkgArchivesDir&"/system/"&kTarget&"/"&tarball) and (not forceDownload):
            info "Tarball already exists for '"&package&"', not gonna download again"
            downSuccess = true
        elif not offline:
            download("https://"&binrepo&"/system/"&kTarget&"/"&tarball, kpkgArchivesDir&"/system/"&kTarget&"/"&tarball)
        else:
            err("attempted to download tarball from binary repository in offline mode")

    if not downSuccess:
        err("couldn't download the binary")

proc install_bin(packages: seq[string], binrepos: seq[string], root: string,
        offline: bool, downloadOnly = false, manualInstallList: seq[string], arch = hostCPU, forceDownload = false, ignoreDownloadErrors = false) =
    ## Downloads and installs binaries.

    var repo: string
    
    isKpkgRunning()
    checkLockfile()
    createLockfile()

    for i in packages:
        down_bin(i, binrepos, root, offline, forceDownload, ignoreDownloadErrors = ignoreDownloadErrors) # TODO: add arch

    if not downloadOnly:
        for i in packages:
            repo = findPkgRepo(i)
            install_pkg(repo, i, root, manualInstallList = manualInstallList, arch = arch)
            info "Installation for "&i&" complete"

    removeLockfile()

proc install*(promptPackages: seq[string], root = "/", yes: bool = false,
        no: bool = false, forceDownload = false, offline = false, downloadOnly = false, ignoreDownloadErrors = false, isUpgrade = false, arch = hostCPU): int =
    ## Download and install a package through a binary repository.
    if promptPackages.len == 0:
        err("please enter a package name", false)

    if not isAdmin():
        err("you have to be root for this action.", false)
    
    var deps: seq[string]
    let init = getInit(root)

    var packages: seq[string]

    let fullRootPath = expandFilename(root)

    for i in promptPackages:
        let currentPackage = lastPathPart(i)
        packages = packages&currentPackage
        if findPkgRepo(currentPackage&"-"&init) != "":
            packages = packages&(currentPackage&"-"&init) 

    try:
        deps = dephandler(packages, root = root)
    except CatchableError:
        err("Dependency detection failed", false)

    printReplacesPrompt(deps, root, true)
    printReplacesPrompt(packages, root)

    let binrepos = getConfigValue("Repositories", "binRepos").split(" ")

    deps = deduplicate(deps&packages)
    printPackagesPrompt(deps.join(" "), yes, no)

    if not (deps.len == 0 and deps == @[""]):
        install_bin(deps, binrepos, fullRootPath, offline,
                downloadOnly = downloadOnly, manualInstallList = promptPackages, arch = arch, forceDownload = forceDownload, ignoreDownloadErrors = ignoreDownloadErrors)

    info("done")
    return 0
