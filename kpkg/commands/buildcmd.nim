import os
import posix
import sets
import tables
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
import ../modules/builder/main
import ../modules/builder/sources
import ../modules/builder/packager
#import ../modules/crossCompilation

proc fakerootWrap(path: string, input: string,
        autocd = "", tests = false, isTest = false, existsTest = false, target = "default", typ: string, passthrough = false): int =
    ## Wraps command with fakeroot and executes it.
    
    if (isTest and not tests) or (tests and not existsTest):
        return 0

    if not isEmptyOrWhitespace(autocd):
        return execEnv(". "&path&"/run && export DESTDIR="&kpkgBuildRoot&" && export ROOT="&kpkgBuildRoot&" && cd "&autocd&" && "&input, typ, passthrough = passthrough)

    return execEnv(". "&path&"/run && export DESTDIR="&kpkgBuildRoot&" && export ROOT="&kpkgBuildRoot&" && cd '"&kpkgSrcDir&"' && "&input, typ, passthrough = passthrough)

proc builder*(package: string, destdir: string, offline = false,
            dontInstall = false, useCacheIfAvailable = false,
                    tests = false, manualInstallList: seq[string], customRepo = "", isInstallDir = false, isUpgrade = false, target = "default", actualRoot = "default", ignorePostInstall = false, noSandbox = false, ignoreTarget = false, ignoreUseCacheIfAvailable = @[""], isBootstrap = false): bool =
    ## Builds the packages.

    debug "builder ran, package: '"&package&"', destdir: '"&destdir&"' root: '"&kpkgSrcDir&"', useCacheIfAvailable: '"&($useCacheIfAvailable)&"'"


    preliminaryChecks(target, actualRoot)

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
    removeDir(kpkgBuildRoot)
    removeDir(kpkgSrcDir)

    let arch = getArch(target)
    let kTarget = getKtarget(target, destdir)

    initEnv(actualPackage, kTarget)

    # Enter into the source directory
    setCurrentDir(kpkgSrcDir)

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
        removeDir(kpkgBuildRoot)
        removeDir(kpkgSrcDir)
        removeLockfile()
        return true
    
    debug "Tarball (and the sum) doesn't exist, going to continue"

    if pkg.isGroup:
        debug "Package is a group package"
        installPkg(repo, actualPackage, destdir, pkg, manualInstallList, ignorePostInstall = ignorePostInstall)
        removeDir(kpkgBuildRoot)
        removeDir(kpkgSrcDir)
        removeLockfile()
        return true

    createDir(kpkgTempDir2)

    var exists = (
            prepare: false, 
            package: false, 
            check: false, 
            packageInstall: false, 
            packageBuild: false, 
            build: false
        )
    
    for i in pkg.functions:
        debug "now checking out '"&i.name&"'"
        case i.name
        of "prepare":
            exists.prepare = true
        of "package":
            exists.package = true
        of "check":
            exists.check = true
        of "build":
            exists.build = true
    
        if "package_"&replace(actualPackage, '-', '_') == i.name:
            exists.packageInstall = true
        
        if "build_"&replace(actualPackage, '-', '_') == i.name:
            exists.packageBuild = true


    var usesGit: bool
    var folder: string

    sourceDownloader(pkg, actualPackage, kpkgSrcDir, path)

    setFilePermissions(kpkgSrcDir, {fpUserExec, fpUserWrite, fpUserRead, fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})
    discard posix.chown(cstring(kpkgSrcDir), 999, 999)
    
    var amountOfFolders: int

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

    if exists.prepare:
        if execEnv(". "&path&"/run"&" && prepare", passthrough = noSandbox) != 0:
            err("prepare failed", true)

    # create cache directory if it doesn't exist
    var ccacheCmds: string
    var cc = getConfigValue("Options", "cc", "cc")
    var cxx = getConfigValue("Options", "cxx", "c++")
    var cmdStr: string
    var cmd3Str: string

    const extraCommands = readFile("./kpkg/modules/runFileExtraCommands.sh")
    writeFile(kpkgSrcDir&"/runfCommands", extraCommands)
    
    var actTarget: string

    let tSplit = target.split("-")
    
    if tSplit.len >= 4:
        actTarget = tSplit[0]&"-"&tSplit[1]&"-"&tSplit[2]
    else:
        actTarget = target

    var bootstrapEnv = ""
    if isBootstrap:
        bootstrapEnv = "export KPKG_BOOTSTRAP=1 && "

    let cmdTemplate = """. """&kpkgSrcDir&"""/runfCommands && """&bootstrapEnv&"""export KPKG_ARCH="""&arch&""" && export KPKG_TARGET="""&actTarget&""" && export KPKG_HOST_TARGET="""&systemTarget(actualRoot)&""" && """

    if actTarget != "default" and actTarget != systemTarget("/"):
        cmdStr = cmdTemplate&cmdStr
        cmd3Str = cmdTemplate&cmd3Str        
    else:
        cmdStr = cmdTemplate.replace(actTarget, systemTarget(destdir))&cmdStr&" unset KPKG_HOST_TARGET && "
        cmd3Str = cmdTemplate.replace(actTarget, systemTarget(destdir))&cmd3Str&" unset KPKG_HOST_TARGET && "

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
        cmdStr = cmdStr&" && export KPKG_EXTRA_ARGUMENTS=\""&override.getSectionValue("Flags", "extraArguments")&"\" && "

    cmdStr = cmdStr&ccacheCmds&"export SRCDIR="&kpkgSrcDir&" && export PACKAGENAME=\""&actualPackage&"\" &&"
    
    let cxxflags = override.getSectionValue("Flags", "cxxflags", getConfigValue("Options", "cxxflags"))
    if not isEmptyOrWhitespace(cxxflags):
      cmdStr = cmdStr&" export CXXFLAGS=\""&cxxflags&"\" &&"
    
    let cflags = override.getSectionValue("Flags", "cflags", getConfigValue("Options", "cflags"))

    if not isEmptyOrWhitespace(cflags):
        cmdStr = cmdStr&" export CFLAGS=\""&cflags&"\" &&"

    if exists.packageInstall:
        cmd3Str = cmd3Str&"package_"&replace(actualPackage, '-', '_')
    elif exists.package:
        cmd3Str = cmd3Str&"package"
    else:
        err "install stage of package doesn't exist, invalid runfile"

    if exists.packageBuild:
        cmdStr = cmdStr&" build_"&replace(actualPackage, '-', '_')
    elif exists.build:
        cmdStr = cmdStr&" build"
    else:
        cmdStr = "true"

    if amountOfFolders != 1:
        debug "amountOfFolder != 1, autocd will not run"
        discard execEnv(cmdStr, "build", passthrough = noSandbox)
        discard fakerootWrap(path, "check", tests = tests,
                isTest = true, existsTest = exists.check, typ = "Tests", passthrough = noSandbox)
        discard fakerootWrap(path, cmd3Str, typ = "Installation", passthrough = noSandbox)
    else:
        debug "amountOfFolders == 1, autocd will run"
        discard execEnv("cd "&folder&" && "&cmdStr, "build", passthrough = noSandbox)
        discard fakerootWrap(path, "check", folder,
                tests = tests, isTest = true, existsTest = exists.check, typ = "Tests", passthrough = noSandbox)
        discard fakerootWrap(path, cmd3Str, folder, typ = "Installation", passthrough = noSandbox)

    discard createPackage(actualPackage, pkg, kTarget)

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
        removeDir(kpkgSrcDir)
        removeDir(kpkgTempDir2)

    return false

proc build*(no = false, yes = false, root = "/",
    packages: seq[string],
            useCacheIfAvailable = true, forceInstallAll = false,
                    dontInstall = false, tests = true, ignorePostInstall = false, isInstallDir = false, isUpgrade = false, target = "default", bootstrap = false): int =
    ## Build and install packages.
    let init = getInit(root)
    var deps: seq[string]
    var depGraph: dependencyGraph
    var gD: seq[string]

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
        # Build the dependency graph once
        (deps, depGraph) = dephandlerWithGraph(packages, isBuild = true,
                root = fullRootPath, forceInstallAll = forceInstallAll, isInstallDir = isInstallDir, ignoreInit = ignoreInit, useBootstrap = bootstrap, useCacheIfAvailable = useCacheIfAvailable)
        
        printReplacesPrompt(deps, fullRootPath, true)
        
        # Check for packages that depend on what we're building
        gD = getDependents(deps)
        
        # If we have dependents, rebuild the graph with them included
        if not isEmptyOrWhitespace(gD.join("")):
            let allPackages = deduplicate(packages&gD)
            (deps, depGraph) = dephandlerWithGraph(allPackages, isBuild = true,
                    root = fullRootPath, forceInstallAll = forceInstallAll, isInstallDir = isInstallDir, ignoreInit = ignoreInit, useBootstrap = bootstrap, useCacheIfAvailable = useCacheIfAvailable)
    except CatchableError:
        raise getCurrentException()

    var p: seq[string]

    for currentPackage in packages:
       p = p&currentPackage 
       if findPkgRepo(currentPackage&"-"&init) != "":
            p = p&(currentPackage&"-"&init)
    
    deps = deduplicate(deps&p)
    
    # If building a package that has bootstrap deps but we're not in bootstrap mode,
    # ensure it's rebuilt AFTER its full BUILD_DEPENDS by moving it to the end
    if not bootstrap:
        for pkg in p:
            let pkgInfo = parsePkgInfo(pkg)
            # Check if package has bootstrap deps by looking at the graph
            if depGraph.nodes.hasKey(pkgInfo.name) and depGraph.nodes[pkgInfo.name].metadata.bsdeps.len > 0:
                # This package has bootstrap deps - move it to the end to ensure
                # it's rebuilt after all its full BUILD_DEPENDS are available
                deps = deps.filterIt(it != pkg)&pkg
    
    printReplacesPrompt(p, fullRootPath, isInstallDir = isInstallDir)
    
    if isInstallDir:
        printPackagesPrompt(deps.join(" "), yes, no, packages, dependents = gD)
    else:
        printPackagesPrompt(deps.join(" "), yes, no, @[""], dependents = gD)

    let pBackup = p

    p = @[]

    if not isInstallDir:
        for i in pBackup:
            let packageSplit = parsePkgInfo(i)
            if "/" in packageSplit.nameWithRepo:
                p = p&packageSplit.name
            else:
                p = p&packageSplit.name
    
    for i in deps:
        try:
            # Rebuild the environment every two weeks so it stays up-to-date.
            # If user needs to rebuild the environment at an earlier time, they can force a rebuild by doing
            # `kpkg clean -e` and building a package.
            if (not dirExists(kpkgEnvPath)) or (fileExists(kpkgEnvPath&"/envDateBuilt") and readFile(kpkgEnvPath&"/envDateBuilt").parse("yyyy-MM-dd") + 2.weeks <= now()):
                removeDir(kpkgEnvPath)
                createEnv(root)
                
            let pkgTmp = parsePkgInfo(i)
            
            # Extract sandbox dependencies from the graph we already built
            # This avoids re-parsing runfiles and recalculating dependencies
            let sandboxDeps = getSandboxDepsFromGraph(pkgTmp.name, depGraph, bootstrap, fullRootPath, forceInstallAll, isInstallDir, ignoreInit)
            
            debug "sandboxDeps for "&pkgTmp.name&" = \""&sandboxDeps.join(" ")&"\""
            var allInstalledDeps: seq[string]
            
            # Prepare overlay directories first (mount tmpfs and create directory structure)
            discard prepareOverlayDirs(error = "preparing overlay directories")
            
            if target != "default" and target != kpkgTarget("/"):
                for d in sandboxDeps:
                    if isEmptyOrWhitespace(d):
                        continue
                    
                    debug "build: installPkg ran for '"&d&"'"
                    installPkg(findPkgRepo(d), d, kpkgOverlayPath&"/upperDir", isUpgrade = false, kTarget = target, manualInstallList = @[], umount = false, disablePkgInfo = true)
            else:
                # Collect all transitive runtime dependencies from the graph for postinstall
                var visited = initHashSet[string]()
                allInstalledDeps = deduplicate(collectRuntimeDepsFromGraph(sandboxDeps, depGraph, visited))

                # Install build dependencies to upperDir (now on tmpfs, before overlay mount)
                installFromRoot(sandboxDeps, root, kpkgOverlayPath&"/upperDir", ignorePostInstall = true)

            # Now mount the overlayfs after build dependencies are installed
            discard mountOverlayFilesystem(error = "mounting overlay filesystem")
            
            # Now run postinstall scripts for all build dependencies (including transitive) in the merged overlay
            # Only for native builds (cross-compilation uses different mechanism)
            if target == "default" or target == kpkgTarget("/"):
                for d in deduplicate(allInstalledDeps):
                    if not isEmptyOrWhitespace(d):
                        runPostInstall(d)

            let packageSplit = parsePkgInfo(i)
            
            # Determine if this is a bootstrap build from the graph
            let isBootstrapBuild = bootstrap and depGraph.nodes.hasKey(pkgTmp.name) and depGraph.nodes[pkgTmp.name].metadata.bsdeps.len > 0
            
            var customRepo = ""
            var isInstallDirFinal: bool 
            var pkgName: string
            
            if isInstallDir and i in packages:
                pkgName = absolutePath(i)
                isInstallDirFinal = true
            else:
                if "/" in packageSplit.nameWithRepo:
                    customRepo = lastPathPart(packageSplit.repo)
                    pkgName = packageSplit.name
                else:
                    pkgName = packageSplit.name
            
            if isBootstrapBuild:
                info("Performing bootstrap build for "&i)
            
            discard builder(pkgName, fullRootPath, offline = false,
                    dontInstall = dontInstall, useCacheIfAvailable = useCacheIfAvailable, tests = tests, manualInstallList = p, customRepo = customRepo, isInstallDir = isInstallDirFinal, isUpgrade = isUpgrade, target = target, actualRoot = root, ignorePostInstall = ignorePostInstall, ignoreUseCacheIfAvailable = gD, isBootstrap = isBootstrapBuild)
            
            success("built "&i&" successfully")
        except CatchableError:
            when defined(release):
                err("Undefined error occured", true)
            else:
                raise getCurrentException()
    
    success("built all packages successfully")
    return 0
