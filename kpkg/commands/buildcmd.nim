import os
import posix
import times
import strutils
import sequtils
import parsecfg
import installcmd
import posix_utils
import ../modules/sqlite
import ../modules/logger
import ../modules/config
import ../modules/lockfile
import ../modules/isolation
import ../modules/runparser
import ../modules/processes
import ../modules/checksums
import ../../common/version 
import ../modules/dephandler
import ../modules/libarchive
import ../modules/downloader
import ../modules/commonTasks
import ../modules/commonPaths
#import ../modules/crossCompilation

proc cleanUp() {.noconv.} =
    ## Cleans up.
    removeLockfile()
    quit(0)


proc fakerootWrap(srcdir: string, path: string, root: string, input: string,
        autocd = "", tests = false, isTest = false, existsTest = 1, target = "default", typ: string, passthrough = false): int =
    ## Wraps command with fakeroot and executes it.
    
    if (isTest and not tests) or (tests and existsTest != 0):
        return 0

    if not isEmptyOrWhitespace(autocd):
        return execEnv(". "&path&"/run && export DESTDIR="&root&" && export ROOT="&root&" && cd "&autocd&" && "&input, typ, passthrough = passthrough)

    return execEnv(". "&path&"/run && export DESTDIR="&root&" && export ROOT="&root&" && cd '"&srcdir&"' && "&input, typ, passthrough = passthrough)

proc builder*(package: string, destdir: string,
    root = kpkgTempDir1&"/build", srcdir = kpkgTempDir1&"/srcdir", offline = false,
            dontInstall = false, useCacheIfAvailable = false,
                    tests = false, manualInstallList: seq[string], customRepo = "", isInstallDir = false, isUpgrade = false, target = "default", actualRoot = "default", ignorePostInstall = false, noSandbox = false, ignoreTarget = false, ignoreUseCacheIfAvailable = @[""]): bool =
    ## Builds the packages.
    
    debug "builder ran, package: '"&package&"', destdir: '"&destdir&"' root: '"&root&"', useCacheIfAvailable: '"&($useCacheIfAvailable)&"'"

    if not isAdmin():
        err("you have to be root for this action.", false)
    
    if target != "default" and actualRoot == "default":
        err("internal error: actualRoot needs to be set when target is used (please open a bug report)")
    
    isKpkgRunning()
    checkLockfile()

    info "starting build for "&package

    setControlCHook(cleanUp)

    # Actual building start here

    var repo: string
    
    if not isEmptyOrWhitespace(customRepo):
      debug "customRepo set to: '"&customRepo&"'"
      repo = "/etc/kpkg/repos/"&customRepo
    else:
      debug "customRepo not set"
      repo = findPkgRepo(package)

    var path: string

    if not dirExists(package) and isInstallDir:
        err("package directory doesn't exist", false)

    if isInstallDir:
        debug "isInstallDir is turned on"
        path = absolutePath(package)
        repo = path.parentDir()
    else:
        path = repo&"/"&package

    if not fileExists(path&"/run"):
        err("runFile doesn't exist, cannot continue", false)
    
    var actualPackage: string

    if isInstallDir:
        actualPackage = lastPathPart(package)
    else:
        actualPackage = package

    # Remove directories if they exist
    removeDir(root)
    removeDir(srcdir)

    var arch: string
    if target != "default":
        arch = target.split("-")[0]
    else:
        arch = uname().machine
    
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

    debug "arch: '"&arch&"'"
    debug "kpkgTarget: '"&kTarget&"'"


    # Create tarball directory if it doesn't exist
    discard existsOrCreateDir("/var/cache")
    discard existsOrCreateDir(kpkgCacheDir)
    discard existsOrCreateDir(kpkgArchivesDir)
    discard existsOrCreateDir(kpkgSourcesDir)
    discard existsOrCreateDir(kpkgSourcesDir&"/"&actualPackage)
    discard existsOrCreateDir(kpkgArchivesDir&"/system")
    discard existsOrCreateDir(kpkgArchivesDir&"/system/"&kTarget)

    # Create required directories
    createDir(root)
    createDir(srcdir)

    setFilePermissions(root, {fpUserExec, fpUserRead, fpGroupExec, fpGroupRead,
            fpOthersExec, fpOthersRead})
    setFilePermissions(srcdir, {fpOthersWrite, fpOthersRead, fpOthersExec})

    # Enter into the source directory
    setCurrentDir(srcdir)

    var pkg: runFile
    try:
        debug "parseRunfile ran from buildcmd"
        pkg = parseRunfile(path)
    except CatchableError:
        err("Unknown error while trying to parse package on repository, possibly broken repo?", false)

    var override: Config
    
    if fileExists("/etc/kpkg/override/"&package&".conf"):
        override = loadConfig("/etc/kpkg/override/"&package&".conf")
    else:
        override = newConfig() # So we don't get storage access errors

    if fileExists(kpkgArchivesDir&"/system/"&kTarget&"/"&actualPackage&"-"&pkg.versionString&".kpkg") and useCacheIfAvailable == true and dontInstall == false and not (actualPackage in ignoreUseCacheIfAvailable):
        
        debug "Tarball (and the sum) already exists, going to install"
        if destdir != "/" and target == "default":
            installPkg(repo, actualPackage, "/", pkg, manualInstallList, ignorePostInstall = ignorePostInstall) # Install package on root too
        
        if kTarget == kpkgTarget(destDir):
            installPkg(repo, actualPackage, destdir, pkg, manualInstallList, ignorePostInstall = ignorePostInstall)
        else:
            info "the package target doesn't match the one on '"&destDir&"', skipping installation"
        removeDir(root)
        removeDir(srcdir)
        return true
    
    debug "Tarball (and the sum) doesn't exist, going to continue"

    if pkg.isGroup:
        debug "Package is a group package"
        installPkg(repo, actualPackage, destdir, pkg, manualInstallList, ignorePostInstall = ignorePostInstall)
        removeDir(root)
        removeDir(srcdir)
        return true

    createLockfile()

    var filename: string

    when defined(release):
        const silentMode = true
    else:
        const silentMode = false
            
    createDir(kpkgTempDir2)

    let existsPrepare = execEnv(". "&path&"/run"&" && command -v prepare", passthrough = noSandbox, silentMode = silentMode)
    let existsInstall = execEnv(". "&path&"/run"&" && command -v package", passthrough = noSandbox, silentMode = silentMode)
    let existsTest = execEnv(". "&path&"/run"&" && command -v check", passthrough = noSandbox, silentMode = silentMode)
    let existsPackageInstall = execEnv(
            ". "&path&"/run"&" && command -v package_"&replace(actualPackage, '-', '_'), passthrough = noSandbox, silentMode = silentMode)
    let existsPackageBuild = execEnv(
            ". "&path&"/run"&" && command -v build_"&replace(actualPackage, '-', '_'), passthrough = noSandbox, silentMode = silentMode)
    let existsBuild = execEnv(
            ". "&path&"/run"&" && command -v build", passthrough = noSandbox, silentMode = silentMode)

    var int = 0
    var usesGit: bool
    var folder: string
    var isLocal = false

    for i in pkg.sources.split(" "):
        if i == "":
            continue

        filename = "/var/cache/kpkg/sources/"&actualPackage&"/"&extractFilename(
                i).strip()

        try:
            if i.startsWith("git::"):
                usesGit = true
                if execEnv("git clone "&i.split("::")[
                        1]&" && cd "&lastPathPart(i.split("::")[
                        1])&" && git branch -C "&i.split("::")[2], passthrough = noSandbox) != 0:
                    err("Cloning repository failed!")

                folder = lastPathPart(i.split("::")[1])
            else:
                if fileExists(path&"/"&i):
                    copyFile(path&"/"&i, extractFilename(i))
                    filename = path&"/"&i
                    isLocal = true
                elif dirExists(path&"/"&i):
                    copyDir(path&"/"&i, lastPathPart(i))
                    filename = path&"/"&i
                    isLocal = true
                elif fileExists(filename):
                    discard
                else:

                    let mirror = override.getSectionValue("Mirror", "sourceMirror", getConfigValue("Options", "sourceMirror", "mirror.kreato.dev/sources"))
                    var raiseWhenFail = true

                    try:
                        if not parseBool(mirror):
                            raiseWhenFail = false
                    except Exception:
                        discard

                    try:
                        download(i, filename, raiseWhenFail = raiseWhenFail)
                    except Exception:
                        info "download failed through sources listed on the runFile, contacting the source mirror"
                        download("https://"&mirror&"/"&actualPackage&"/"&extractFilename(i).strip(), filename, raiseWhenFail = false)

                # git cloning doesn't support sum checking
                var actualDigest: string
                var expectedDigest: string
                var sumType: string

                try:
                    expectedDigest = pkg.b2sum.split(" ")[int]
                    if isEmptyOrWhitespace(expectedDigest): raise
                    sumType = "b2"
                except Exception:
                    discard
                
                if sumType != "b2":
                    try:
                        expectedDigest = pkg.sha512sum.split(" ")[int]
                        if isEmptyOrWhitespace(expectedDigest): raise
                        sumType = "sha512"
                    except Exception:
                        discard

                if sumType != "sha512" and sumType != "b2":
                    try:
                        expectedDigest = pkg.sha256sum.split(" ")[int]
                        if isEmptyOrWhitespace(expectedDigest): raise
                        sumType = "sha256"
                    except Exception:
                        err "runFile doesn't have proper checksums"
                
                if not isLocal:
                    actualDigest = getSum(filename, sumType)

                    if expectedDigest != actualDigest:
                        removeFile(filename)
                        err sumType&"sum doesn't match for "&i&"\nExpected: '"&expectedDigest&"'\nActual: '"&actualDigest&"'"

                # Add symlink for compatibility purposes
                if not fileExists(path&"/"&i) and (not isLocal):
                    createSymlink(filename, extractFilename(i).strip())

                int = int+1
        except CatchableError:
            when defined(release):
                err "Unknown error occured while trying to download the sources"
            debug "Unknown error while trying to download sources"
            raise getCurrentException()

    setFilePermissions(srcdir, {fpUserExec, fpUserWrite, fpUserRead, fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})
    discard posix.chown(cstring(srcdir), 999, 999)
    
    var amountOfFolders: int

    if pkg.extract and (not usesGit):
        
        for i in pkg.sources.split(" "):
            debug "trying to extract \""&extractFilename(i)&"\""
            try:
                discard extract(extractFilename(i))
            except Exception:
                debug "extraction failed, continuing"
    

    for i in toSeq(walkDir(".")):
        debug i.path
        if dirExists(i.path):
            folder = absolutePath(i.path)
            amountOfFolders = amountOfFolders + 1
            setFilePermissions(folder, {fpUserExec, fpUserWrite, fpUserRead, fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})
        discard posix.chown(cstring(folder), 999, 999)
        for i in toSeq(walkDirRec(folder, {pcFile, pcLinkToFile, pcDir, pcLinkToDir})):
            discard posix.chown(cstring(i), 999, 999)
        
    if amountOfFolders == 1 and (not isEmptyOrWhitespace(folder)):
        try:
            setCurrentDir(folder)
        except Exception:
            when defined(release):
                err("Unknown error occured while trying to enter the source directory")

            debug $folder
            raise getCurrentException()

    if existsPrepare == 0:
        if execEnv(". "&path&"/run"&" && prepare", passthrough = noSandbox) != 0:
            err("prepare failed", true)

    # Run ldconfig beforehand for any errors
    #discard execEnv("ldconfig")
     
    # create cache directory if it doesn't exist
    var ccacheCmds: string
    var cc = getConfigValue("Options", "cc", "cc")
    var cxx = getConfigValue("Options", "cxx", "c++")
    var cmdStr: string
    var cmd3Str: string

    const extraCommands = readFile("./kpkg/modules/runFileExtraCommands.sh")
    writeFile(srcdir&"/runfCommands", extraCommands)

    if arch == "amd64":
        arch = "x86_64" # For compatibility
    
    var actTarget: string

    let tSplit = target.split("-")
    
    if tSplit.len >= 4:
        actTarget = tSplit[0]&"-"&tSplit[1]&"-"&tSplit[2]
    else:
        actTarget = target

    if actTarget != "default" and actTarget != systemTarget("/"):
        cmdStr = ". "&srcdir&"/runfCommands && export KPKG_ARCH="&arch&" && export KPKG_TARGET="&actTarget&" && export KPKG_HOST_TARGET="&systemTarget(actualRoot)&" && "&cmdStr
        cmd3Str = ". "&srcdir&"/runfCommands && export KPKG_ARCH="&arch&" && export KPKG_TARGET="&actTarget&" && export KPKG_HOST_TARGET="&systemTarget(actualRoot)&" && "&cmd3Str
    else:
        cmdStr = ". "&srcdir&"/runfCommands && export KPKG_ARCH="&arch&" && export KPKG_TARGET="&systemTarget(destdir)&" && "&cmdStr
        cmd3Str = ". "&srcdir&"/runfCommands && export KPKG_ARCH="&arch&" && export KPKG_TARGET="&systemTarget(destdir)&" && "&cmd3Str

    if parseBool(override.getSectionValue("Other", "ccache", getConfigValue("Options", "ccache", "false"))) and packageExists("ccache"):
      
      if not dirExists(kpkgCacheDir&"/ccache"):
        createDir(kpkgCacheDir&"/ccache")
      
      setFilePermissions(kpkgCacheDir&"/ccache", {fpUserExec, fpUserWrite, fpUserRead, fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})
      discard posix.chown(cstring(kpkgCacheDir&"/ccache"), 999, 999)
      ccacheCmds = "export CCACHE_DIR="&kpkgCacheDir&"/ccache && export PATH=\"/usr/lib/ccache:$PATH\" &&"
    
    cmdStr = cmdStr&". "&path&"/run"

    if actTarget == "default" or actTarget == systemTarget("/"):
        cmdStr = cmdStr&" && export CC=\""&cc&"\" && export CXX=\""&cxx&"\" && "
   
    if not isEmptyOrWhitespace(override.getSectionValue("Flags", "extraArguments")):
        cmdStr = cmdStr&" export KPKG_EXTRA_ARGUMENTS=\""&override.getSectionValue("Flags", "extraArguments")&"\" && "

    cmdStr = cmdStr&ccacheCmds&" export SRCDIR="&srcdir&" && export PACKAGENAME=\""&actualPackage&"\" &&"
    
    let cxxflags = override.getSectionValue("Flags", "cxxflags", getConfigValue("Options", "cxxflags"))
    if not isEmptyOrWhitespace(cxxflags):
      cmdStr = cmdStr&" export CXXFLAGS=\""&cxxflags&"\" &&"
    
    let cflags = override.getSectionValue("Flags", "cflags", getConfigValue("Options", "cflags"))

    if not isEmptyOrWhitespace(cflags):
        cmdStr = cmdStr&" export CFLAGS=\""&cflags&"\" &&"

    if existsPackageInstall == 0:
        cmd3Str = cmd3Str&"package_"&replace(actualPackage, '-', '_')
    elif existsInstall == 0:
        cmd3Str = cmd3Str&"package"
    else:
        err "install stage of package doesn't exist, invalid runfile"

    if existsPackageBuild == 0:
        cmdStr = cmdStr&" build_"&replace(actualPackage, '-', '_')
    elif existsBuild == 0:
        cmdStr = cmdStr&" build"
    else:
        cmdStr = "true"

    if amountOfFolders != 1:
        debug "amountOfFolder != 1, autocd will not run"
        discard execEnv(cmdStr, "build", passthrough = noSandbox)
        discard fakerootWrap(srcdir, path, root, "check", tests = tests,
                isTest = true, existsTest = existsTest, typ = "Tests", passthrough = noSandbox)
        discard fakerootWrap(srcdir, path, root, cmd3Str, typ = "Installation", passthrough = noSandbox)
    else:
        debug "amountOfFolders == 1, autocd will run"
        discard execEnv("cd "&folder&" && "&cmdStr, "build", passthrough = noSandbox)
        discard fakerootWrap(srcdir, path, root, "check", folder,
                tests = tests, isTest = true, existsTest = existsTest, typ = "Tests", passthrough = noSandbox)
        discard fakerootWrap(srcdir, path, root, cmd3Str, folder, typ = "Installation", passthrough = noSandbox)

    var tarball = kpkgArchivesDir&"/system/"&kTarget
    
    createDir(tarball)
    
    tarball = tarball&"/"&actualPackage&"-"&pkg.versionString&".kpkg"
    
    # pkgInfo.ini
    var pkgInfo = newConfig()

    pkgInfo.setSectionKey("", "pkgVer", pkg.versionString)
    pkgInfo.setSectionKey("", "apiVer", ver)

    var depsInfo: string
    

    for dep in pkg.deps:
        
        if isEmptyOrWhitespace(dep):
            continue 

        var pkg: Package
        
        try:
            if packageExists(dep, kpkgEnvPath):
                pkg = getPackage(dep, kpkgEnvPath)
            elif packageExists(dep, kpkgOverlayPath&"/upperDir"):
                pkg = getPackage(dep, kpkgOverlayPath&"/upperDir/")
            else:
                when defined(release):
                    err "Unknown error occured while generating binary package"
                else:
                    debug "Unknown error occured while generating binary package"
                    raise getCurrentException()

        except CatchableError:
            raise 
        if isEmptyOrWhitespace(depsInfo):
            depsInfo = (dep&"#"&pkg.version)
        else:
            depsInfo = depsInfo&" "&(dep&"#"&pkg.version)

    pkgInfo.setSectionKey("", "depends", depsInfo)
        
    pkgInfo.writeConfig(root&"/pkgInfo.ini")

    # pkgsums.ini
    var dict = newConfig()
    
    for file in toSeq(walkDirRec(root, {pcFile, pcLinkToFile, pcDir, pcLinkToDir})):
        if "pkgInfo.ini" == relativePath(file, root): continue
        if dirExists(file) or symlinkExists(file):
            dict.setSectionKey("", "\""&relativePath(file, root)&"\"", "")
        else:
            dict.setSectionKey("", "\""&relativePath(file, root)&"\"", getSum(file, "b2"))
        
    dict.writeConfig(root&"/pkgsums.ini")
    
    if execCmdKpkg("bsdtar -czf "&tarball&" -C "&root&" .") != 0:
        err "creating binary tarball failed"
    #createArchive(tarball, root)
    
    #writeFile(tarball&".sum.b2", getSum(tarball, "b2"))


    # Install package to root aswell so dependency errors doesnt happen
    # because the dep is installed to destdir but not root.
    if destdir != "/" and not packageExists(actualPackage) and (not dontInstall) and target == "default":
        installPkg(repo, actualPackage, "/", pkg, manualInstallList, isUpgrade = isUpgrade, ignorePostInstall = ignorePostInstall)

    if (not dontInstall) and (kTarget == kpkgTarget(destDir)) :
        installPkg(repo, actualPackage, destdir, pkg, manualInstallList, isUpgrade = isUpgrade, ignorePostInstall = ignorePostInstall)
    else:
        info "the package target doesn't match the one on '"&destDir&"', skipping installation"

    removeLockfile()
    
    when defined(release):
        removeDir(srcdir)
        removeDir(kpkgTempDir2)

    return false

proc build*(no = false, yes = false, root = "/",
    packages: seq[string],
            useCacheIfAvailable = true, forceInstallAll = false,
                    dontInstall = false, tests = true, ignorePostInstall = false, isInstallDir = false, isUpgrade = false, target = "default"): int =
    ## Build and install packages.
    let init = getInit(root)
    var deps: seq[string]

    if packages.len == 0:
        err("please enter a package name", false)
    
    var fullRootPath = expandFilename(root)
    var ignoreInit = false
    
    #if target != "default":
    #    if not crossCompilerExists(target):
    #        err "cross-compiler for '"&target&"' doesn't exist, please build or install it (see handbook/cross-compilation)"
        
    #    fullRootPath = root&"/usr/"&target
    #    ignoreInit = true

    try:
        deps = deduplicate(dephandler(packages, bdeps = true, isBuild = true,
                root = fullRootPath, forceInstallAll = forceInstallAll, isInstallDir = isInstallDir, ignoreInit = ignoreInit)&dephandler(
                        packages, isBuild = true, root = fullRootPath,
                        forceInstallAll = forceInstallAll, isInstallDir = isInstallDir, ignoreInit = ignoreInit))
    except CatchableError:
        raise getCurrentException()

    printReplacesPrompt(deps, fullRootPath, true)

    var p: seq[string]

    for currentPackage in packages:
       p = p&currentPackage 
       if findPkgRepo(currentPackage&"-"&init) != "":
            p = p&(currentPackage&"-"&init)

    

    deps = deduplicate(deps&p)

    let gD = getDependents(deps)
    if not isEmptyOrWhitespace(gD.join("")):
        deps = deps&gD

    printReplacesPrompt(p, fullRootPath, isInstallDir = isInstallDir)
    
    if isInstallDir:
        printPackagesPrompt(deps.join(" "), yes, no, packages, dependents = gD)
    else:
        printPackagesPrompt(deps.join(" "), yes, no, @[""], dependents = gD)

    let pBackup = p

    p = @[]

    if not isInstallDir:
        for i in pBackup:
            let packageSplit = i.split("/")
            if packageSplit.len > 1:
                p = p&packageSplit[1]
            else:
                p = p&packageSplit[0]
    
    var depsToClean: seq[string]

    for i in deps:
        try:
            # Rebuild the environment every two weeks so it stays up-to-date.
            # If user needs to rebuild the environment at an earlier time, they can force a rebuild by doing
            # `kpkg clean -e` and building a package.
            if (not dirExists(kpkgEnvPath)) or (fileExists(kpkgEnvPath&"/envDateBuilt") and readFile(kpkgEnvPath&"/envDateBuilt").parse("yyyy-MM-dd") + 2.weeks <= now()):
                removeDir(kpkgEnvPath)
                createEnv(root)
                
            discard mountOverlay(error = "mounting overlay")
            # We set isBuild to false here as we don't want build dependencies of other packages on the sandbox.
            debug "parseRunfile ran from buildcmd, depsToClean"
            depsToClean = deduplicate(parseRunfile(findPkgRepo(i)&"/"&i).bdeps&dephandler(@[i], isBuild = false, root = fullRootPath, forceInstallAll = true, isInstallDir = isInstallDir, ignoreInit = ignoreInit))
            debug "depsToClean = \""&depsToClean.join(" ")&"\""
            if target != "default" and target != kpkgTarget("/"):
                for d in depsToClean:
                    if isEmptyOrWhitespace(d):
                        continue
                    debug "build: installPkg ran for '"&d&"'"
                    installPkg(findPkgRepo(d), d, kpkgOverlayPath&"/upperDir", isUpgrade = false, kTarget = target, manualInstallList = @[], umount = false, disablePkgInfo = true)
            else:
                for d in depsToClean:
                    installFromRoot(d, root, kpkgOverlayPath&"/upperDir")

            let packageSplit = i.split("/")
            
            var customRepo = ""
            var isInstallDirFinal: bool 
            var pkgName: string
            
            if isInstallDir and i in packages:
                pkgName = absolutePath(i)
                isInstallDirFinal = true
            else:
                if packageSplit.len > 1:
                    customRepo = packageSplit[0]
                    pkgName = packageSplit[1]
                else:
                    pkgName = packageSplit[0]

            discard builder(pkgName, fullRootPath, offline = false,
                    dontInstall = dontInstall, useCacheIfAvailable = useCacheIfAvailable, tests = tests, manualInstallList = p, customRepo = customRepo, isInstallDir = isInstallDirFinal, isUpgrade = isUpgrade, target = target, actualRoot = root, ignorePostInstall = ignorePostInstall, ignoreUseCacheIfAvailable = gD)
            
            success("built "&i&" successfully")
        except CatchableError:
            when defined(release):
                err("Undefined error occured", true)
            else:
                raise getCurrentException()
    
    success("built all packages successfully")
    return 0
