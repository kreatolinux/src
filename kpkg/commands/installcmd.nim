import os
import diff
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
import ../modules/commonTasks
import ../modules/removeInternal

var threadsUsed: int

try:
    threadsUsed = parseInt(getConfigValue("Parallelization", "threadsUsed"))
    if threadsUsed < 1:
        echo "kpkg: warning: threadsUsed in /etc/kpkg/kpkg.conf can't be below 1. Please update your configuration."
        raise
except Exception:
    threadsUsed = 4

setControlCHook(ctrlc)

proc diff(a: seq[string], b: seq[string]): seq[string] =
    ## Returns the differences b has in a string.
    var r: seq[string]

    for span in spanSlices(a, b):
        case span.tag
        of tagReplace:
            for text in span.b:
                r = r&text
        of tagInsert:
            for text in span.b:
                r = r&text
        else:
            discard

    return r

proc install_pkg*(repo: string, package: string, root: string, built = false) =
    ## Installs an package.

    var pkg: runFile
    try:
        pkg = parse_runfile(repo&"/"&package)
    except CatchableError:
        raise

    for i in pkg.conflicts:
        if dirExists(root&"/var/cache/kpkg/installed/"&i):
            err(i&" conflicts with "&package)

    createDir("/tmp")
    createDir("/tmp/kpkg")

    if dirExists(root&"/var/cache/kpkg/installed/"&package):

        echo "kpkg: package already installed, reinstalling"

        createDir("/tmp/kpkg/reinstall")

        moveDir(root&"/var/cache/kpkg/installed/"&package,
                "/tmp/kpkg/reinstall/"&package&"-old")

    let tarball = "/var/cache/kpkg/archives/arch/"&hostCPU&"/kpkg-tarball-"&package&"-"&pkg.versionString&".tar.gz"

    if sha256hexdigest(readAll(open(tarball)))&"  "&tarball != readAll(open(
        tarball&".sum")):
        err("sha256sum doesn't match for "&package, false)

    setCurrentDir("/var/cache/kpkg/archives")

    discard existsOrCreateDir(root&"/var/cache")
    discard existsOrCreateDir(root&"/var/cache/kpkg")
    discard existsOrCreateDir(root&"/var/cache/kpkg/installed")
    removeDir(root&"/var/cache/kpkg/installed/"&package)
    copyDir(repo&"/"&package, root&"/var/cache/kpkg/installed/"&package)

    var cmd: tuple[output: string, exitCode: int]
    if not built:
        createDir("/tmp/kpkg/extractDir")
        cmd = execCmdEx("tar -xvf "&tarball&" -C /tmp/kpkg/extractDir")
        if cmd.exitCode != 0:
            err("extracting the tarball failed for "&package, false)
    else:
        cmd = execCmdEx("tar -tf "&tarball)

    for i in pkg.replaces:
        if dirExists("/var/cache/kpkg/installed/"&i):
            discard removeInternal(i, root)
        createSymlink(package, root&"/var/cache/kpkg/installed/"&i)

    if built:
        mv("/tmp/kpkg/build", root)
    else:
        mv("/tmp/kpkg/extractDir", root)

    writeFile(root&"/var/cache/kpkg/installed/"&package&"/list_files", cmd.output)

    removeDir("/tmp/kpkg/extractDir")

    # Run ldconfig afterwards for any new libraries
    discard execProcess("ldconfig")

    if dirExists("/tmp/kpkg/reinstall/"&package&"-old"):
        let d = diff(readFile("/tmp/kpkg/reinstall/"&package&"-old/list_files").split(
                "\n"), readFile(
                "/var/cache/kpkg/installed/"&package&"/list_files").split("\n"))
        if d.len != 0:
            writeFile("/tmp/kpkg/reinstall/list_files", d.join("\n"))
            discard removeInternal("reinstall", root,
                    installedDir = "/tmp/kpkg", ignoreReplaces = true)

    removeDir("/tmp/kpkg")

    var existsPostinstall = execCmdEx(
            ". "&repo&"/"&package&"/run"&" && command -v postinstall").exitCode

    if existsPostinstall == 0:
        if execShellCmd(". "&repo&"/"&package&"/run"&" && postinstall") != 0:
            err("postinstall failed")

    for i in pkg.optdeps:
        echo i

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
            pkg = parse_runfile(repo&"/"&package)
        except CatchableError:
            raise

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
        offline: bool, downloadOnly = false, init = "") =
    ## Downloads and installs binaries.

    var repo: string

    for i in packages:
        if threadsUsed == 1:
            down_bin(i, binrepos, root, offline)
        else:
            spawn down_bin(i, binrepos, root, offline)
        
        if isEmptyOrWhitespace(init):
          continue

        if findPkgRepo(i&"-"&init) != "" and not dirExists(root&"/var/cache/kpkg/installed/"&i&"-"&init):
          if threadsUsed == 1:
              down_bin(i&"-"&init, binrepos, root, offline)
          else:
              spawn down_bin(i&"-"&init, binrepos, root, offline)


    if threadsUsed != 1:
        sync()

    if not downloadOnly:
        for i in packages:
            repo = findPkgRepo(i)
            install_pkg(repo, i, root)
  
            if isEmptyOrWhitespace(init):
              continue

            if findPkgRepo(i&"-"&init) != "" and not dirExists(root&"/var/cache/kpkg/installed/"&i&"-"&init):
              install_pkg(repo, i&"-"&init, root)

            echo "Installation for "&i&" complete"

proc install*(promptPackages: seq[string], root = "/", yes: bool = false,
        no: bool = false, offline = false, downloadOnly = false): string =
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
        raise

    printReplacesPrompt(deps, root)
    printReplacesPrompt(packages, root)

    printPackagesPrompt(deps.join(" ")&" "&packages.join(" "), yes, no)

    var depsDelete: string

    let fullRootPath = expandFilename(root)

    for i in deps:
        if dirExists(fullRootPath&"/var/cache/kpkg/installed/"&i):
            depsDelete = depsDelete&" "&i

    for i in depsDelete.split(" ").filterit(it.len != 0):
        deps.delete(deps.find(i))

    let binrepos = getConfigValue("Repositories", "binRepos").split(" ")

    if not (deps.len == 0 and deps == @[""]):
        install_bin(deps, binrepos, fullRootPath, offline,
                downloadOnly = downloadOnly, init = init)
        install_bin(packages, binrepos, fullRootPath, offline,
                downloadOnly = downloadOnly, init = init)

    return "kpkg: done"
