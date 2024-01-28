import os
import posix
import osproc
import strutils
import sequtils
import parsecfg
import installcmd
import posix_utils
import ../modules/logger
import ../modules/shadow
import ../modules/config
import ../modules/lockfile
import ../modules/runparser
import ../modules/processes
import ../modules/checksums
import ../modules/dephandler
import ../modules/libarchive
import ../modules/downloader
import ../modules/commonTasks
import ../modules/crossCompilation

proc cleanUp() {.noconv.} =
    ## Cleans up.
    removeLockfile()
    quit(0)


proc fakerootWrap(srcdir: string, path: string, root: string, input: string,
        autocd = "", tests = false, isTest = false, existsTest = 1, target = "default", typ: string): int =
    ## Wraps command with fakeroot and executes it.
    
    if (isTest and not tests) or (tests and existsTest != 0):
        return 0

    if not isEmptyOrWhitespace(autocd):
        return execCmdKpkg("fakeroot -- /bin/sh -c '. "&path&"/run && export DESTDIR="&root&" && export ROOT=$DESTDIR && cd "&autocd&" && "&input&"'", typ)

    return execCmdKpkg("fakeroot -- /bin/sh -c '. "&path&"/run && export DESTDIR="&root&" && export ROOT=$DESTDIR && cd '"&srcdir&"' && "&input&"'", typ)

proc builder*(package: string, destdir: string,
    root = "/opt/kpkg/build", srcdir = "/opt/kpkg/srcdir", offline = false,
            dontInstall = false, useCacheIfAvailable = false,
                    tests = false, manualInstallList: seq[string], customRepo = "", isInstallDir = false, isUpgrade = false, target = "default", actualRoot = "default", ignorePostInstall = false): bool =
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
    
    if arch == "x86_64":
        arch = "amd64" # for compat reasons

    debug "arch: '"&arch&"'"

    # Create tarball directory if it doesn't exist
    discard existsOrCreateDir("/var/cache")
    discard existsOrCreateDir("/var/cache/kpkg")
    discard existsOrCreateDir("/var/cache/kpkg/archives")
    discard existsOrCreateDir("/var/cache/kpkg/sources")
    discard existsOrCreateDir("/var/cache/kpkg/sources/"&actualPackage)
    discard existsOrCreateDir("/var/cache/kpkg/archives/arch")
    discard existsOrCreateDir("/var/cache/kpkg/archives/arch/"&arch)

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
        pkg = parseRunfile(path)
    except CatchableError:
        err("Unknown error while trying to parse package on repository, possibly broken repo?", false)

    var override: Config
    
    if fileExists("/etc/kpkg/override/"&package&".conf"):
        override = loadConfig("/etc/kpkg/override/"&package&".conf")
    else:
        override = newConfig() # So we don't get storage access errors

    if fileExists("/var/cache/kpkg/archives/arch/"&arch&"/kpkg-tarball-"&actualPackage&"-"&pkg.versionString&".tar.gz") and
            fileExists(
            "/var/cache/kpkg/archives/arch/"&arch&"/kpkg-tarball-"&actualPackage&"-"&pkg.versionString&".tar.gz.sum") and
            useCacheIfAvailable == true and dontInstall == false:
        
        debug "Tarball (and the sum) already exists, going to install"
        if destdir != "/" and target == "default":
            installPkg(repo, actualPackage, "/", pkg, manualInstallList, ignorePostInstall = ignorePostInstall) # Install package on root too

        installPkg(repo, actualPackage, destdir, pkg, manualInstallList, arch = arch, ignorePostInstall = ignorePostInstall)
        removeDir(root)
        removeDir(srcdir)
        return true
    
    debug "Tarball (and the sum) doesn't exist, going to continue"

    if pkg.isGroup:
        debug "Package is a group package"
        installPkg(repo, actualPackage, destdir, pkg, manualInstallList, arch = arch, ignorePostInstall = ignorePostInstall)
        removeDir(root)
        removeDir(srcdir)
        return true

    createLockfile()

    var filename: string

    let existsPrepare = execCmdEx(". "&path&"/run"&" && command -v prepare").exitCode
    let existsInstall = execCmdEx(". "&path&"/run"&" && command -v package").exitCode
    let existsTest = execCmdEx(". "&path&"/run"&" && command -v check").exitCode
    let existsPackageInstall = execCmdEx(
            ". "&path&"/run"&" && command -v package_"&replace(actualPackage, '-', '_')).exitCode
    let existsPackageBuild = execCmdEx(
            ". "&path&"/run"&" && command -v build_"&replace(actualPackage, '-', '_')).exitCode
    let existsBuild = execCmdEx(
            ". "&path&"/run"&" && command -v build").exitCode

    var int = 0
    var usesGit: bool
    var folder: string

    for i in pkg.sources.split(" "):
        if i == "":
            continue

        filename = "/var/cache/kpkg/sources/"&actualPackage&"/"&extractFilename(
                i).strip()

        try:
            if i.startsWith("git::"):
                usesGit = true
                if execCmdKpkg(sboxWrap("git clone "&i.split("::")[
                        1]&" && cd "&lastPathPart(i.split("::")[
                        1])&" && git branch -C "&i.split("::")[2])) != 0:
                    err("Cloning repository failed!")

                folder = lastPathPart(i.split("::")[1])
            else:
                if fileExists(path&"/"&i):
                    copyFile(path&"/"&i, extractFilename(i))
                    filename = path&"/"&i
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
                

                actualDigest = getSum(filename, sumType)

                if expectedDigest != actualDigest:
                    removeFile(filename)
                    err sumType&"sum doesn't match for "&i&"\nExpected: '"&expectedDigest&"'\nActual: '"&actualDigest&"'"

                # Add symlink for compatibility purposes
                if not fileExists(path&"/"&i):
                    createSymlink(filename, extractFilename(i).strip())

                int = int+1
        except CatchableError:
            when defined(release):
                err "Unknown error occured while trying to download the sources"
            debug "Unknown error while trying to download sources"
            raise getCurrentException()

    # Create homedir of _kpkg temporarily
    createDir(homeDir)
    setFilePermissions(homeDir, {fpUserExec, fpUserWrite, fpUserRead, fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})
    discard posix.chown(cstring(homeDir), 999, 999)
    setFilePermissions(srcdir, {fpUserExec, fpUserWrite, fpUserRead, fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})
    discard posix.chown(cstring(srcdir), 999, 999)

    if existsPrepare != 0 and not usesGit:
        try:
          discard extract(filename)
        except Exception:
          debug "extraction failed, continuing"
        for i in toSeq(walkDir(".")):
          if dirExists(i.path):
            folder = absolutePath(i.path)
            break

        setFilePermissions(folder, {fpUserExec, fpUserWrite, fpUserRead, fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})
        discard posix.chown(cstring(folder), 999, 999)
        for i in toSeq(walkDirRec(folder, {pcFile, pcLinkToFile, pcDir, pcLinkToDir})):
          discard posix.chown(cstring(i), 999, 999)

        if pkg.sources.split(" ").len == 1:
            try:
                setCurrentDir(folder)
            except Exception:
                when defined(release):
                    err("Unknown error occured while trying to enter the source directory")

                debug $folder
                raise getCurrentException()
    elif existsPrepare == 0:
        if execCmdKpkg("su -s /bin/sh _kpkg -c '. "&path&"/run"&" && prepare'") != 0:
            err("prepare failed", true)

    # Run ldconfig beforehand for any errors
    discard execProcess("ldconfig")
     
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

    if target != "default":
        cmdStr = ". "&srcdir&"/runfCommands && export KPKG_ARCH="&arch&" && export KPKG_TARGET="&target&" && export KPKG_HOST_TARGET="&systemTarget(actualRoot)&" && "&cmdStr
        cmd3Str = ". "&srcdir&"/runfCommands && export KPKG_ARCH="&arch&" && export KPKG_TARGET="&target&" && export KPKG_HOST_TARGET="&systemTarget(actualRoot)&" && "&cmd3Str
    else:
        cmdStr = ". "&srcdir&"/runfCommands && export KPKG_ARCH="&arch&" && export KPKG_TARGET="&systemTarget(destdir)&" && "&cmdStr
        cmd3Str = ". "&srcdir&"/runfCommands && export KPKG_ARCH="&arch&" && export KPKG_TARGET="&systemTarget(destdir)&" && "&cmd3Str

    if arch == "x86_64":
        arch = "amd64" # Revert back the value
    
    if parseBool(override.getSectionValue("Other", "ccache", getConfigValue("Options", "ccache", "false"))) and dirExists("/var/cache/kpkg/installed/ccache"):
      
      if not dirExists("/var/cache/kpkg/ccache"):
        createDir("/var/cache/kpkg/ccache")
      
      setFilePermissions("/var/cache/kpkg/ccache", {fpUserExec, fpUserWrite, fpUserRead, fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})
      discard posix.chown(cstring("/var/cache/kpkg/ccache"), 999, 999)
      ccacheCmds = "export CCACHE_DIR=/var/cache/kpkg/ccache && export PATH=\"/usr/lib/ccache:$PATH\" &&"
    
    cmdStr = cmdStr&". "&path&"/run"

    if target == "default":
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

    if pkg.sources.split(" ").len == 1:
        if existsPrepare == 0:
            debug "prepare() exist, autocd will not run"
            discard execCmdKpkg(sboxWrap(cmdStr), "build")
            discard fakerootWrap(srcdir, path, root, "check", tests = tests,
                    isTest = true, existsTest = existsTest, typ = "Tests")
            discard fakerootWrap(srcdir, path, root, cmd3Str, typ = "Installation")
        else:
            debug "prepare() doesn't exist, autocd will run"
            discard execCmdKpkg(sboxWrap("cd "&folder&" && "&cmdStr), "build")
            discard fakerootWrap(srcdir, path, root, "check", folder,
                    tests = tests, isTest = true, existsTest = existsTest, typ = "Tests")
            discard fakerootWrap(srcdir, path, root, cmd3Str, folder, typ = "Installation")

    else:
        discard execCmdKpkg(sboxWrap(cmdStr), "build")
        discard fakerootWrap(srcdir, path, root, "check", tests = tests,
                isTest = true, existsTest = existsTest, typ = "Tests")
        discard fakerootWrap(srcdir, path, root, cmd3Str, typ = "Installation")

    var tarball = "/var/cache/kpkg/archives/arch/"
    
    tarball = tarball&arch
    createDir(tarball)
    
    tarball = tarball&"/kpkg-tarball-"&actualPackage&"-"&pkg.versionString&".tar.gz"

    if execCmdKpkg("bsdtar -czf "&tarball&" -C "&root&" .") != 0:
        err "creating binary tarball failed"
    #createArchive(tarball, root)

    writeFile(tarball&".sum.b2", getSum(tarball, "b2"))


    # Install package to root aswell so dependency errors doesnt happen
    # because the dep is installed to destdir but not root.
    if destdir != "/" and not dirExists(
            "/var/cache/kpkg/installed/"&actualPackage) and (not dontInstall) and target == "default":
        installPkg(repo, actualPackage, "/", pkg, manualInstallList, isUpgrade = isUpgrade, arch = arch, ignorePostInstall = ignorePostInstall)

    if not dontInstall:
        installPkg(repo, actualPackage, destdir, pkg, manualInstallList, isUpgrade = isUpgrade, arch = arch, ignorePostInstall = ignorePostInstall)

    removeLockfile()

    removeDir(srcdir)
    removeDir(homeDir)

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
    
    if target != "default":
        if not crossCompilerExists(target):
            err "cross-compiler for '"&target&"' doesn't exist, please build or install it (see handbook/cross-compilation)"
        
        fullRootPath = root&"/usr/"&target
        ignoreInit = true

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

    printReplacesPrompt(p, fullRootPath, isInstallDir = isInstallDir)
    
    if isInstallDir:
        printPackagesPrompt(deps.join(" "), yes, no, packages)
    else:
        printPackagesPrompt(deps.join(" "), yes, no, @[""])

    let pBackup = p

    p = @[]

    if not isInstallDir:
        for i in pBackup:
            let packageSplit = i.split("/")
            if packageSplit.len > 1:
                p = p&packageSplit[1]
            else:
                p = p&packageSplit[0]

    for i in deps:
        try:
            
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
                    dontInstall = dontInstall, useCacheIfAvailable = useCacheIfAvailable, tests = tests, manualInstallList = p, customRepo = customRepo, isInstallDir = isInstallDirFinal, isUpgrade = isUpgrade, target = target, actualRoot = root, ignorePostInstall = ignorePostInstall)
            success("built "&i&" successfully")
        except CatchableError:
            when defined(release):
                err("Undefined error occured", true)
            else:
                raise getCurrentException()

    success("built all packages successfully")
    return 0
