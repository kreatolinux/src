import os
import osproc
import strutils
import sequtils
import parsecfg
import ../modules/sqlite
import ../modules/config
import ../modules/logger
import ../modules/lockfile
import ../modules/isolation
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

proc installPkg*(repo: string, package: string, root: string, runf = runFile(
        isParsed: false), manualInstallList: seq[string], isUpgrade = false, kTarget = kpkgTarget(root), ignorePostInstall = false, umount = true, disablePkgInfo = false, ignorePreInstall = false, basePackage = false, version = "") =
    ## Installs a package.

    var pkg: runFile
    
    try:
        if runf.isParsed:
            pkg = runf
        else:
            debug "parseRunfile ran, installPkg"
            pkg = parseRunfile(repo&"/"&package)
    except CatchableError:
        err("Unknown error while trying to parse package on repository, possibly broken repo?")

    debug "installPkg ran, repo: '"&repo&"', package: '"&package&"', root: '"&root&"', manualInstallList: '"&manualInstallList.join(" ")&"'"
    
    let isUpgradeActual = (packageExists(package, root) and getPackage(package, root).version != pkg.versionString) or isUpgrade

    if isUpgradeActual:
        let existsPkgPreUpgrade = execCmdEx(". "&repo&"/"&package&"/run"&" && command -v preupgrade_"&replace(package, '-', '_')).exitCode
        let existsPreUpgrade = execCmdEx(". "&repo&"/"&package&"/run"&" && command -v preupgrade").exitCode

        if existsPkgPreUpgrade == 0:
            if execCmdKpkg(". "&repo&"/"&package&"/run"&" && preupgrade_"&replace(
                    package, '-', '_')).exitCode != 0:
                err("preupgrade failed")
            
        if existsPreUpgrade == 0:
            if execCmdKpkg(". "&repo&"/"&package&"/run"&" && preupgrade").exitCode != 0:
                err("preupgrade failed")

    if not packageExists(package, root):
 
        var existsPkgPreinstall = execCmdEx(
                ". "&repo&"/"&package&"/run"&" && command -v preinstall_"&replace(
                        package, '-', '_')).exitCode
        var existsPreinstall = execCmdEx(
                ". "&repo&"/"&package&"/run"&" && command -v preinstall").exitCode

        if existsPkgPreinstall == 0:
            if execCmdKpkg(". "&repo&"/"&package&"/run"&" && preinstall_"&replace(
                    package, '-', '_')).exitCode != 0:
                if ignorePreInstall:
                    warn "preinstall failed"
                else:
                    err("preinstall failed")
        elif existsPreinstall == 0:
            if execCmdKpkg(". "&repo&"/"&package&"/run"&" && preinstall").exitCode != 0:
                if ignorePreInstall:
                    warn "preinstall failed"
                else:
                    err("preinstall failed")




    let isGroup = pkg.isGroup

    for i in pkg.conflicts:
        if packageExists(i, root):
            err(i&" conflicts with "&package)
    
    removeDir("/tmp/kpkg/reinstall/"&package&"-old")
    createDir("/tmp")
    createDir("/tmp/kpkg")

    var tarball: string

    var pkgVersion = pkg.versionString

    if not isEmptyOrWhitespace(version):
        pkgVersion = version

    if not isGroup:
        tarball = kpkgArchivesDir&"/system/"&kTarget&"/"&package&"-"&pkgVersion&".kpkg"
        
    setCurrentDir(kpkgArchivesDir)
    
    for i in pkg.replaces:
        if packageExists(i, root):
            # Check if the package is actually installed or just replaced by another package
            let replacedInfo = isReplaced(i, root)
            if replacedInfo.replaced:
                # Package is already replaced by another package, skip removal
                debug "Package '"&i&"' is already replaced by '"&replacedInfo.package.name&"', skipping removal"
                continue
            
            if kTarget != kpkgTarget(root):
                removeInternal(i, root, initCheck = false)
            else:
                removeInternal(i, root)
    
    if (packageExists(package, root)) and (not isGroup):

        info "package already installed, reinstalling"
        if kTarget != kpkgTarget(root):
            removeInternal(package, root, ignoreReplaces = true, noRunfile = true, initCheck = false)
        else:
            removeInternal(package, root, ignoreReplaces = true, noRunfile = false, depCheck = false)

    discard existsOrCreateDir(root&"/var")
    discard existsOrCreateDir(root&"/var/cache")
    discard existsOrCreateDir(root&kpkgCacheDir)
    
    if not isGroup:
        var extractTarball: seq[string]
        let kpkgInstallTemp = kpkgTempDir1&"/install-"&package
        if dirExists(kpkgInstallTemp):
            removeDir(kpkgInstallTemp)
        
        createDir(kpkgInstallTemp)
        setCurrentDir(kpkgInstallTemp)
        try:
          extractTarball = extract(tarball, kpkgInstallTemp)
        except Exception:
            when defined(release):
                err("extracting the tarball failed for "&package)
            else:
                removeLockfile()
                raise getCurrentException()
        
        var dict = loadConfig(kpkgInstallTemp&"/pkgsums.ini")
            
        # Checking loop
        for file in extractTarball:
            if "pkgsums.ini" == lastPathPart(file) or "pkgInfo.ini" == lastPathPart(file): continue
            let value = dict.getSectionValue("", relativePath(file, kpkgInstallTemp))
            let doesFileExist = (fileExists(kpkgInstallTemp&"/"&file) and not symlinkExists(kpkgInstallTemp&"/"&file))
            
            #let rootFilePath = absolutePath(root&"/"&relativePath(file, kpkgInstallTemp))
            #if fileExists(rootFilePath):
            #    err("\""&rootFilePath&"\" already exists in filesystem, installation failed")

            if isEmptyOrWhitespace(value) and not doesFileExist:
                continue
                
            if isEmptyOrWhitespace(value) and doesFileExist:
                debug file
                err("package sums invalid")

            if getSum(kpkgInstallTemp&"/"&file, "b2") != value:
                err("sum for file '"&file&"' invalid")
        
        if fileExists(kpkgInstallTemp&"/pkgInfo.ini") and (not disablePkgInfo): # pkgInfo is recommended, but not required

            var dict2 = loadConfig(kpkgInstallTemp&"/pkgInfo.ini")

            for dep in dict2.getSectionValue("", "depends").split(" "):
                
                if isEmptyOrWhitespace(dep):
                    continue

                let depClean = dep.strip()
                if isEmptyOrWhitespace(depClean):
                    continue

                let hashPos = depClean.find('#')

                if hashPos < 0 or hashPos == depClean.high:
                    warn "pkgInfo lists dependency '"&depClean&"', but it is missing a version; skipping check"
                    continue

                let depName = depClean[0 ..< hashPos].strip()
                let depVersion = depClean[(hashPos + 1) .. depClean.high].strip()

                if isEmptyOrWhitespace(depName) or isEmptyOrWhitespace(depVersion):
                    warn "pkgInfo lists dependency '"&depClean&"', but it is missing a name or version; skipping check"
                    continue

                if not packageExists(depName, root):
                    warn "pkgInfo lists dependency '"&depName&"', but it is not installed at '"&root&"'; skipping version check"
                    continue
                 
                var db: Package
                try:
                    db = getPackage(depName, root)
                except:
                    if isDebugMode():
                        debug "getPackage failed for '"&depName&"' at root '"&root&"'"
                        debug "pkgInfo.ini content:"
                        try:
                            let pkgInfoContent = readFile(kpkgInstallTemp&"/pkgInfo.ini")
                            for line in pkgInfoContent.splitLines():
                                debug "  "&line
                        except:
                            debug "  (could not read pkgInfo.ini file)"
                    raise

                if db.version != depVersion:
                    warn "this package is built with '"&depName&"#"&depVersion&"', while the system has '"&depName&"#"&db.version&"'"
                    warn "installing anyway, but issues may occur"
                    warn "this may be an error in the future"
    
        
        var mI = false
    
        if package in manualInstallList:
            info "Setting as manually installed"
            mI = true

        var pkgType = newPackage(package, pkgVersion, pkg.release, pkg.epoch, pkg.deps.join("!!k!!"), pkg.bdeps.join("!!k!!"), pkg.backup.join("!!k!!"), pkg.replaces.join("!!k!!"), pkg.desc, mI, pkg.isGroup, basePackage, root)
            
        # Installation loop 
        for file in extractTarball:
            let relPath = relativePath(file, kpkgInstallTemp)

            if relPath in pkg.backup and (fileExists(root&"/"&relPath) or dirExists(root&"/"&relPath)):
                debug "\""&file&"\" is in pkg.backup, not installing"
                dict.delSectionKey("", relativePath(file, kpkgInstallTemp))
                continue
            
            #if fileExists(root&"/"&relPath):
            #    err "file \""&relPath&"\" already exists on filesystem, cannot continue"

            if "pkgsums.ini" == lastPathPart(file):
                pkgSumsToSQL(kpkgInstallTemp&"/"&file, pkgType, root)
                continue

            if "pkgInfo.ini" == lastPathPart(file):
                # TODO: add pkgInfo class to modules/sqlite
                continue
        
            


            let doesFileExist = (fileExists(kpkgInstallTemp&"/"&file) or symlinkExists(kpkgInstallTemp&"/"&file))
            if doesFileExist:
                if not dirExists(root&"/"&file.parentDir()):
                    createDirWithPermissionsAndOwnership(kpkgInstallTemp&"/"&file.parentDir(), root&"/"&file.parentDir())
                copyFileWithPermissionsAndOwnership(kpkgInstallTemp&"/"&file, root&"/"&file)
            elif dirExists(kpkgInstallTemp&"/"&file) and not (dirExists(root&"/"&file) or symlinkExists(root&"/"&file)):
                createDirWithPermissionsAndOwnership(kpkgInstallTemp&"/"&file, root&"/"&file)
    else:
        # Register group packages in the database
        var mI = false
        if package in manualInstallList:
            info "Setting as manually installed"
            mI = true
        
        discard newPackage(package, pkgVersion, pkg.release, pkg.epoch, pkg.deps.join("!!k!!"), pkg.bdeps.join("!!k!!"), pkg.backup.join("!!k!!"), pkg.replaces.join("!!k!!"), pkg.desc, mI, pkg.isGroup, basePackage, root)

    # Run ldconfig afterwards for any new libraries
    discard execProcess("ldconfig")
    
    if dirExists(kpkgOverlayPath) and dirExists(kpkgMergedPath) and umount:
        discard umountOverlay(error = "unmounting overlays")
    
    when defined(release):
        removeDir(kpkgTempDir1)
        removeDir(kpkgTempDir2)
    
    var existsPkgPostinstall = execCmdEx(
            ". "&repo&"/"&package&"/run"&" && command -v postinstall_"&replace(
                    package, '-', '_')).exitCode
    var existsPostinstall = execCmdEx(
            ". "&repo&"/"&package&"/run"&" && command -v postinstall").exitCode

    if existsPkgPostinstall == 0:
        if execCmdKpkg(". "&repo&"/"&package&"/run"&" && postinstall_"&replace(
                package, '-', '_')).exitCode != 0:
            if ignorePostInstall:
                warn "postinstall failed"
            else:
                err("postinstall failed")
    elif existsPostinstall == 0:
        if execCmdKpkg(". "&repo&"/"&package&"/run"&" && postinstall").exitCode != 0:
            if ignorePostInstall:
                warn "postinstall failed"
            else:
                err("postinstall failed")

    
    if isUpgradeActual:
        var existsPkgPostUpgrade = execCmdEx(". "&repo&"/"&package&"/run"&" && command -v postupgrade_"&replace(package, '-', '_')).exitCode
        var existsPostUpgrade = execCmdEx(". "&repo&"/"&package&"/run"&" && command -v postupgrade").exitCode
        
        if existsPkgPostUpgrade == 0:
            if execCmdKpkg(". "&repo&"/"&package&"/run"&" && postupgrade_"&replace(package, '-', '_')).exitCode != 0:
                err("postupgrade failed")
        
        if existsPostUpgrade == 0:
            if execCmdKpkg(". "&repo&"/"&package&"/run"&" && postupgrade").exitCode != 0:
                err("postupgrade failed")

    for i in pkg.optdeps:
        info(i)

proc down_bin*(package: string, binrepos: seq[string], root: string,
        offline: bool, forceDownload = false, ignoreDownloadErrors = false, kTarget = kpkgTarget(root), version = "", customPath = "", ignoreErrors = false) =
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
            debug "parseRunfile ran, down_bin"
            pkg = parseRunfile(repo&"/"&package)
        except CatchableError:
            const msg = "Unknown error while trying to parse package on repository, possibly broken repo?"
            if ignoreErrors:
                debug msg
                return
            else:
                err(msg)

        if pkg.isGroup:
            return
        
        var pkgVersion = pkg.versionString
        
        if not isEmptyOrWhitespace(version):
            pkgVersion = version

        let tarball = package&"-"&pkgVersion&".kpkg"
        var path = kpkgArchivesDir&"/system/"&kTarget&"/"&tarball
        if not isEmptyOrWhitespace(customPath):
            path = customPath

        if fileExists(path) and (not forceDownload):
            info "Tarball already exists for '"&package&"', not gonna download again"
            downSuccess = true
        elif not offline:
            try:
                download("https://"&binrepo&"/archives/system/"&kTarget&"/"&tarball, path)
                downSuccess = true
            except:
                const msg = "an error occured while downloading package binary"
                if ignoreErrors:
                    debug msg
                    return
                else:
                    err(msg)
        else:
            const msg = "attempted to download tarball from binary repository in offline mode"
            debug path
            if ignoreErrors:
                debug msg
                return
            else:
                err(msg)

    if not downSuccess and not ignoreDownloadErrors:
        err("couldn't download the binary")

proc install_bin(packages: seq[string], binrepos: seq[string], root: string,
        offline: bool, downloadOnly = false, manualInstallList: seq[string], kTarget = kpkgTarget(root), forceDownload = false, ignoreDownloadErrors = false, forceDownloadPackages = @[""], basePackage = false) =
    ## Downloads and installs binaries.

    isKpkgRunning()
    checkLockfile()
    createLockfile()

    for i in packages:
        let pkgParsed = parsePkgInfo(i)
        var fdownload = false
        if i in forceDownloadPackages or forceDownload:
            fdownload = true
        down_bin(pkgParsed.name, binrepos, root, offline, fdownload, ignoreDownloadErrors = ignoreDownloadErrors, kTarget = kTarget, version = pkgParsed.version)

    if not downloadOnly:
        for i in packages:
            let pkgParsed = parsePkgInfo(i)
            installPkg(pkgParsed.repo, pkgParsed.name, root, manualInstallList = manualInstallList, kTarget = kTarget, basePackage = basePackage, version = pkgParsed.version)
            info "Installation for "&i&" complete"

    removeLockfile()

proc install*(promptPackages: seq[string], root = "/", yes: bool = false,
        no: bool = false, forceDownload = false, offline = false, downloadOnly = false, ignoreDownloadErrors = false, isUpgrade = false, target = "default", basePackage = false): int =
    ## Install a package from a binary, from a repository or locally.
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
        if findPkgRepo(parsePkgInfo(i).name&"-"&init) != "":
            packages = packages&(parsePkgInfo(i).name&"-"&init) 

    try:
        deps = dephandler(packages, root = root)
    except CatchableError:
        err("Dependency detection failed", false)

    printReplacesPrompt(deps, root, true)
    printReplacesPrompt(packages, root)

    let binrepos = getConfigValue("Repositories", "binRepos").split(" ")

    deps = deduplicate(deps&packages)
    
    let gD = getDependents(deps)
    if not isEmptyOrWhitespace(gD.join("")):
        deps = deps&gD

    printPackagesPrompt(deps.join(" "), yes, no, dependents = gD, binary = true)
    
    var kTarget = target

    if target == "default":
        kTarget = kpkgTarget(root)

    if not (deps.len == 0 and deps == @[""]):
        install_bin(deps, binrepos, fullRootPath, offline,
                downloadOnly = downloadOnly, manualInstallList = promptPackages, kTarget = kTarget, forceDownload = forceDownload, ignoreDownloadErrors = ignoreDownloadErrors, basePackage = basePackage)

    info("done")
    return 0
