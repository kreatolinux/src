import os
import osproc
import strutils
import sequtils
import installcmd
import libsha/sha256
import ../modules/logger
import ../modules/shadow
import ../modules/config
import ../modules/runparser
import ../modules/dephandler
import ../modules/downloader
import ../modules/commonTasks

const lockfile = "/tmp/kpkg.lock"

proc cleanUp() {.noconv.} =
    ## Cleans up.
    removeFile(lockfile)
    quit(0)

proc fakerootWrap(srcdir: string, path: string, root: string, input: string,
        autocd = "", tests = false, isTest = false, existsTest = 1): int =
    ## Wraps command with fakeroot and executes it.

    if (isTest and not tests) or (tests and existsTest != 0):
        return 0

    if not isEmptyOrWhitespace(autocd):
        return execShellCmd("fakeroot -- /bin/sh -c '. "&path&"/run && export DESTDIR="&root&" && export ROOT=$DESTDIR && cd "&autocd&" && "&input&"'")

    return execShellCmd("fakeroot -- /bin/sh -c '. "&path&"/run && export DESTDIR="&root&" && export ROOT=$DESTDIR && cd '"&srcdir&"' && "&input&"'")

proc builder*(package: string, destdir: string,
    root = "/opt/kpkg/build", srcdir = "/opt/kpkg/srcdir", offline = false,
            dontInstall = false, useCacheIfAvailable = false,
                    tests = false): bool =
    ## Builds the packages.

    if not isAdmin():
        err("you have to be root for this action.", false)

    if fileExists(lockfile):
        err("lockfile exists, will not proceed", false)

    info "starting build for "&package

    setControlCHook(cleanUp)

    # Actual building start here

    var repo = findPkgRepo(package)

    var path = repo&"/"&package

    # Remove directories if they exist
    removeDir(root)
    removeDir(srcdir)

    # Create tarball directory if it doesn't exist
    discard existsOrCreateDir("/var/cache")
    discard existsOrCreateDir("/var/cache/kpkg")
    discard existsOrCreateDir("/var/cache/kpkg/archives")
    discard existsOrCreateDir("/var/cache/kpkg/sources")
    discard existsOrCreateDir("/var/cache/kpkg/sources/"&package)
    discard existsOrCreateDir("/var/cache/kpkg/archives/arch")
    discard existsOrCreateDir("/var/cache/kpkg/archives/arch/"&hostCPU)

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
        pkg = parse_runfile(path)
    except CatchableError:
        err("Unknown error while trying to parse package on repository, possibly broken repo?", false)

    if fileExists("/var/cache/kpkg/archives/arch/"&hostCPU&"/kpkg-tarball-"&package&"-"&pkg.versionString&".tar.gz") and
            fileExists(
            "/var/cache/kpkg/archives/arch/"&hostCPU&"/kpkg-tarball-"&package&"-"&pkg.versionString&".tar.gz.sum") and
            useCacheIfAvailable == true and dontInstall == false:

        if destdir != "/":
            install_pkg(repo, package, "/", pkg) # Install package on root too

        install_pkg(repo, package, destdir, pkg)
        removeDir(root)
        removeDir(srcdir)
        return true

    if pkg.isGroup:
        install_pkg(repo, package, destdir, pkg)
        removeDir(root)
        removeDir(srcdir)
        return true

    writeFile(lockfile, "") # Create lockfile

    var filename: string

    let existsPrepare = execCmdEx(". "&path&"/run"&" && command -v prepare").exitCode
    let existsInstall = execCmdEx(". "&path&"/run"&" && command -v package").exitCode
    let existsTest = execCmdEx(". "&path&"/run"&" && command -v check").exitCode
    let existsPackageInstall = execCmdEx(
            ". "&path&"/run"&" && command -v package_"&replace(package, '-', '_')).exitCode
    let existsPackageBuild = execCmdEx(
            ". "&path&"/run"&" && command -v build_"&replace(package, '-', '_')).exitCode
    let existsBuild = execCmdEx(
            ". "&path&"/run"&" && command -v build").exitCode

    var int = 0
    var usesGit: bool
    var folder: seq[string]

    for i in pkg.sources.split(" "):
        if i == "":
            continue

        filename = "/var/cache/kpkg/sources/"&package&"/"&extractFilename(
                i).strip()

        try:
            if i.startsWith("git::"):
                usesGit = true
                if execShellCmd(sboxWrap("git clone "&i.split("::")[
                        1]&" && cd "&lastPathPart(i.split("::")[
                        1])&" && git branch -C "&i.split("::")[2])) != 0:
                    err("Cloning repository failed!")

                folder = @[lastPathPart(i.split("::")[1])]
            else:
                if fileExists(path&"/"&i):
                    copyFile(path&"/"&i, extractFilename(i))
                    filename = path&"/"&i
                elif fileExists(filename):
                    discard
                else:
                    download(i, filename)

                # git cloning doesn't support sha256sum checking
                var actualDigest = sha256hexdigest(readAll(open(
                        filename)))

                var expectedDigest = pkg.sha256sum.split(" ")[int]

                if expectedDigest != actualDigest:
                    err "sha256sum doesn't match for "&i&"\nExpected: "&expectedDigest&"\nActual: "&actualDigest

                # Add symlink for compatibility purposes
                if not fileExists(path&"/"&i):
                    createSymlink(filename, extractFilename(i).strip())

                int = int+1
        except CatchableError:
            when defined(release):
                err "Unknown error occured while trying to download the sources"
            debug "Unknown error while trying to download sources"
            raise

    # Create homedir of _kpkg temporarily
    createDir(homeDir)
    setFilePermissions(homeDir, {fpOthersWrite, fpOthersRead, fpOthersExec})

    if existsPrepare != 0 and not usesGit:
        folder = absolutePath(execProcess(
                "su -s /bin/sh _kpkg -c \"bsdtar -tzf "&filename&" 2>/dev/null | head -1 | cut -f1 -d'/'\"")).splitWhitespace.filterit(
                it.len != 0)
        discard execProcess("su -s /bin/sh _kpkg -c 'bsdtar -xvf "&filename&"'")
        if pkg.sources.split(" ").len == 1:
            try:
                setCurrentDir(folder[0])
            except Exception:
                when defined(release):
                    err("Unknown error occured while trying to enter the source directory")

                debug $folder
                raise
    elif existsPrepare == 0:
        if execShellCmd("su -s /bin/sh _kpkg -c '. "&path&"/run"&" && prepare'") != 0:
            err("prepare failed", true)

    var cmd: int
    var cmd2: int
    var cmd3: int

    # Run ldconfig beforehand for any errors
    discard execProcess("ldconfig")

    var cmdStr = ". "&path&"/run"&" && export CC="&getConfigValue("Options",
            "cc")&" && export CXX="&getConfigValue("Options",
                    "cxx")&" && export CCACHE_DIR=/opt/kpkg/cache &&"
    var cmd3Str: string

    if existsPackageInstall == 0:
        cmd3Str = "package_"&replace(package, '-', '_')
    elif existsInstall == 0:
        cmd3Str = "package"
    else:
        err "install stage of package doesn't exist, invalid runfile"

    if existsPackageBuild == 0:
        cmdStr = cmdStr&" build_"&replace(package, '-', '_')
    elif existsBuild == 0:
        cmdStr = cmdStr&" build"
    else:
        cmdStr = "true"

    if pkg.sources.split(" ").len == 1:
        if existsPrepare == 0:
            cmd = execShellCmd(sboxWrap(cmdStr))
            cmd2 = fakerootWrap(srcdir, path, root, "check", tests = tests,
                    isTest = true, existsTest = existsTest)
            cmd3 = fakerootWrap(srcdir, path, root, cmd3Str)
        else:
            cmd = execShellCmd(sboxWrap("cd "&folder[0]&" && "&cmdStr))
            cmd2 = fakerootWrap(srcdir, path, root, "check", folder[0],
                    tests = tests, isTest = true, existsTest = existsTest)
            cmd3 = fakerootWrap(srcdir, path, root, cmd3Str, folder[0])

    else:
        cmd = execShellCmd(sboxWrap(cmdStr))
        cmd2 = fakerootWrap(srcdir, path, root, "check", tests = tests,
                isTest = true, existsTest = existsTest)
        cmd3 = fakerootWrap(srcdir, path, root, cmd3Str)

    if cmd != 0:
        err("build failed")

    if cmd2 != 0:
        err("Tests failed")

    if cmd3 != 0:
        err("Installation failed")

    let tarball = "/var/cache/kpkg/archives/arch/"&hostCPU&"/kpkg-tarball-"&package&"-"&pkg.versionString&".tar.gz"

    discard execProcess("tar -czvf "&tarball&" -C "&root&" .")

    writeFile(tarball&".sum", sha256hexdigest(readAll(open(
        tarball)))&"  "&tarball)


    # Install package to root aswell so dependency errors doesnt happen
    # because the dep is installed to destdir but not root.
    if destdir != "/" and not dirExists(
            "/var/cache/kpkg/installed/"&package) and (not dontInstall):
        install_pkg(repo, package, "/", pkg)

    if not dontInstall:
        install_pkg(repo, package, destdir, pkg)

    removeFile(lockfile)

    removeDir(srcdir)
    removeDir(homeDir)

    return false

proc build*(no = false, yes = false, root = "/",
    packages: seq[string],
            useCacheIfAvailable = true, forceInstallAll = false,
                    dontInstall = false, tests = true): int =
    ## Build and install packages
    let init = getInit(root)
    var deps: seq[string]

    if packages.len == 0:
        err("please enter a package name", false)

    try:
        deps = deduplicate(dephandler(packages, bdeps = true, isBuild = true,
                root = root, forceInstallAll = forceInstallAll)&dephandler(
                        packages, isBuild = true, root = root,
                        forceInstallAll = forceInstallAll))
    except CatchableError:
        raise

    printReplacesPrompt(deps, root, true)

    var p = packages

    for i in packages:
        if findPkgRepo(i&"-"&init) != "":
            p = p&(i&"-"&init)

    deps = deduplicate(deps&p)

    printReplacesPrompt(p, root)
    printPackagesPrompt(deps.join(" "), yes, no)

    let fullRootPath = expandFilename(root)

    for i in deps:
        try:
            discard builder(i, fullRootPath, offline = false,
                    useCacheIfAvailable = useCacheIfAvailable, tests = tests)
            success("installed "&i&" successfully")
        except CatchableError:
            when defined(release):
                err("Undefined error occured", true)
            else:
                raise

    success("built all packages successfully")
    return 0
