import os
import osproc
import strutils
import sequtils
import threadpool
import libsha/sha256
import ../modules/config
import ../modules/logger
import ../modules/runparser
import ../modules/downloader
import ../modules/dephandler
import ../modules/libarchive
import ../modules/commonTasks
import ../modules/removeInternal

var threadsUsed: int

threadsUsed = parseInt(getConfigValue("Parallelization", "threadsUsed"))
if threadsUsed < 1:
    warn "threadsUsed in /etc/kpkg/kpkg.conf can't be below 1. Please update your configuration."
    info "Setting threadsUsed to 1"
    threadsUsed = 1

setControlCHook(ctrlc)

proc installPkg*(repo: string, package: string, root: string, runf = runFile(
        isParsed: false), manualInstallList: seq[string]) =
    ## Installs an package.

    var pkg: runFile

    try:
        if runf.isParsed:
            pkg = runf
        else:
            pkg = parseRunfile(repo&"/"&package)
    except CatchableError:
        err("Unknown error while trying to parse package on repository, possibly broken repo?", false)

    let isGroup = pkg.isGroup

    for i in pkg.conflicts:
        if dirExists(root&"/var/cache/kpkg/installed/"&i):
            err(i&" conflicts with "&package)

    removeDir("/tmp/kpkg/reinstall/"&package&"-old")
    createDir("/tmp")
    createDir("/tmp/kpkg")

    if dirExists(root&"/var/cache/kpkg/installed/"&package) and
            not symlinkExists(root&"/var/cache/kpkg/installed/"&package) and not isGroup:

        info "package already installed, reinstalling"
        
        removeInternal(package)

    var tarball: string

    if not isGroup:
        tarball = "/var/cache/kpkg/archives/arch/"&hostCPU&"/kpkg-tarball-"&package&"-"&pkg.versionString&".tar.gz"

        if sha256hexdigest(readAll(open(tarball)))&"  "&tarball != readAll(open(
            tarball&".sum")):
            err("sha256sum doesn't match for "&package, false)

    setCurrentDir("/var/cache/kpkg/archives")

    for i in pkg.replaces:
        if symlinkExists(root&"/var/cache/kpkg/installed/"&i):
            removeFile(root&"/var/cache/kpkg/installed/"&i)
        elif dirExists(root&"/var/cache/kpkg/installed/"&i):
            removeInternal(i, root)
        createSymlink(package, root&"/var/cache/kpkg/installed/"&i)

    discard existsOrCreateDir(root&"/var/cache")
    discard existsOrCreateDir(root&"/var/cache/kpkg")
    discard existsOrCreateDir(root&"/var/cache/kpkg/installed")
    removeDir(root&"/var/cache/kpkg/installed/"&package)
    copyDir(repo&"/"&package, root&"/var/cache/kpkg/installed/"&package)

    if not isGroup:
        var extractTarball: seq[string]
        try:
          extractTarball = extract(tarball, root, pkg.backup)
        except Exception:
            removeDir(root&"/var/cache/kpkg/installed/"&package)
            err("extracting the tarball failed for "&package, false)

        writeFile(root&"/var/cache/kpkg/installed/"&package&"/list_files", extractTarball.join("\n"))

    # Run ldconfig afterwards for any new libraries
    discard execProcess("ldconfig")

    removeDir("/tmp/kpkg")
    removeDir("/opt/kpkg")

    if package in manualInstallList:
      info "Setting as manually installed"
      writeFile("/var/cache/kpkg/installed/"&package&"/manualInstall", "")

    var existsPkgPostinstall = execCmdEx(
            ". "&repo&"/"&package&"/run"&" && command -v postinstall_"&replace(
                    package, '-', '_')).exitCode
    var existsPostinstall = execCmdEx(
            ". "&repo&"/"&package&"/run"&" && command -v postinstall").exitCode

    if existsPkgPostinstall == 0:
        if execShellCmd(". "&repo&"/"&package&"/run"&" && postinstall_"&replace(
                package, '-', '_')) != 0:
            err("postinstall failed")
    elif existsPostinstall == 0:
        if execShellCmd(". "&repo&"/"&package&"/run"&" && postinstall") != 0:
            err("postinstall failed")

    for i in pkg.optdeps:
        info(i)

proc down_bin(package: string, binrepos: seq[string], root: string,
        offline: bool) =
    ## Downloads binaries.
    setMinPoolSize(1)

    setMaxPoolSize(threadsUsed)

    discard existsOrCreateDir("/var/")
    discard existsOrCreateDir("/var/cache")
    discard existsOrCreateDir("/var/cache/kpkg")
    discard existsOrCreateDir("/var/cache/kpkg/archives")
    discard existsOrCreateDir("/var/cache/kpkg/archives/arch")
    discard existsOrCreateDir("/var/cache/kpkg/archives/arch/"&hostCPU)

    setCurrentDir("/var/cache/kpkg/archives")
    var downSuccess: bool

    for binrepo in binrepos:
        var repo: string

        repo = findPkgRepo(package)
        var pkg: runFile

        try:
            pkg = parseRunfile(repo&"/"&package)
        except CatchableError:
            err("Unknown error while trying to parse package on repository, possibly broken repo?", false)

        if pkg.isGroup:
            return

        let tarball = "kpkg-tarball-"&package&"-"&pkg.versionString&".tar.gz"
        let chksum = tarball&".sum"

        if fileExists("/var/cache/kpkg/archives/arch/"&hostCPU&"/"&tarball) and
                fileExists("/var/cache/kpkg/archives/arch/"&hostCPU&"/"&chksum):
            echo "Tarball already exists, not gonna download again"
            downSuccess = true
        elif not offline:
            echo "Downloading tarball for "&package
            try:
                download("https://"&binrepo&"/arch/"&hostCPU&"/"&tarball,
                    "/var/cache/kpkg/archives/arch/"&hostCPU&"/"&tarball)
                echo "Downloading checksums for "&package
                download("https://"&binrepo&"/arch/"&hostCPU&"/"&chksum,
                    "/var/cache/kpkg/archives/arch/"&hostCPU&"/"&chksum)
                downSuccess = true
            except CatchableError:
                discard
        else:
            err("attempted to download tarball from binary repository in offline mode", false)

    if not downSuccess:
        err("couldn't download the binary", false)

proc install_bin(packages: seq[string], binrepos: seq[string], root: string,
        offline: bool, downloadOnly = false, manualInstallList: seq[string]) =
    ## Downloads and installs binaries.

    var repo: string

    for i in packages:
        if threadsUsed == 1:
            down_bin(i, binrepos, root, offline)
        else:
            spawn down_bin(i, binrepos, root, offline)

    threadpool.sync()

    if not downloadOnly:
        for i in packages:
            repo = findPkgRepo(i)
            install_pkg(repo, i, root, manualInstallList = manualInstallList)
            info "Installation for "&i&" complete"

proc install*(promptPackages: seq[string], root = "/", yes: bool = false,
        no: bool = false, offline = false, downloadOnly = false): int =
    ## Download and install a package through a binary repository
    if promptPackages.len == 0:
        err("please enter a package name", false)

    if not isAdmin():
        err("you have to be root for this action.", false)

    var deps: seq[string]
    let init = getInit(root)

    var packages = promptPackages

    try:
        deps = dephandler(packages, root = root)
    except CatchableError:
        err("Dependency detection failed", false)

    let fullRootPath = expandFilename(root)

    for i in promptPackages:
        if findPkgRepo(i&"-"&init) != "":
            packages = packages&(i&"-"&init)

    printReplacesPrompt(deps, root, true)
    printReplacesPrompt(packages, root)

    let binrepos = getConfigValue("Repositories", "binRepos").split(" ")

    deps = deduplicate(deps&packages)
    printPackagesPrompt(deps.join(" "), yes, no)

    if not (deps.len == 0 and deps == @[""]):
        install_bin(deps, binrepos, fullRootPath, offline,
                downloadOnly = downloadOnly, manualInstallList = promptPackages)

    info("done")
    return 0
