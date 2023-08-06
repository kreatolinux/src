import os
import osproc
import strutils
import sequtils
import asyncdispatch
import libsha/sha256
import ../modules/config
import ../modules/logger
import ../modules/runparser
import ../modules/downloader
import ../modules/dephandler

proc install_pkg*(repo: string, package: string, root: string, binary = false,
        builddir = "/tmp/kpkg/build") =
    ## Installs an package.

    var pkg: runFile
    try:
        pkg = parse_runfile(repo&"/"&package)
    except CatchableError:
        raise

    for i in pkg.conflicts:
        if dirExists("/var/cache/kpkg/installed/"&i):
            err(i&" conflicts with "&package)

    let tarball = "/var/cache/kpkg/archives/arch/"&hostCPU&"/kpkg-tarball-"&pkg.pkg&"-"&pkg.versionString&".tar.gz"

    if sha256hexdigest(readAll(open(tarball)))&"  "&tarball != readAll(open(
        tarball&".sum")):
        err("sha256sum doesn't match for"&pkg.pkg, false)

    setCurrentDir("/var/cache/kpkg/archives")

    discard existsOrCreateDir(root&"/var/cache")
    discard existsOrCreateDir(root&"/var/cache/kpkg")
    discard existsOrCreateDir(root&"/var/cache/kpkg/installed")
    removeDir(root&"/var/cache/kpkg/installed/"&package)
    copyDir(repo&"/"&package, root&"/var/cache/kpkg/installed/"&package)

    writeFile(root&"/var/cache/kpkg/installed/"&package&"/list_files",
            execProcess("tar -tf"&tarball))

    discard execProcess("tar -hxf"&tarball&" -C "&root)

    # Run ldconfig afterwards for any new libraries
    discard execProcess("ldconfig")

    var existsPostinstall = execCmdEx(
            ". "&repo&"/"&package&"/run"&" && command -v postinstall").exitCode

    if existsPostinstall == 0:
        if execShellCmd(". "&repo&"/"&package&"/run"&" && postinstall") != 0:
            err("postinstall failed")

proc install_bin(packages: seq[string], binrepo: string, root: string,
        offline: bool, downloadOnly = false) =
    ## Downloads and installs binaries.

    discard existsOrCreateDir("/var/")
    discard existsOrCreateDir("/var/cache")
    discard existsOrCreateDir("/var/cache/kpkg")
    discard existsOrCreateDir("/var/cache/kpkg/archives")
    discard existsOrCreateDir("/var/cache/kpkg/archives/arch")
    discard existsOrCreateDir("/var/cache/kpkg/archives/arch/"&hostCPU)
    setCurrentDir("/var/cache/kpkg/archives")

    var repo: string

    for i in packages:
        repo = findPkgRepo(i)
        var pkg: runFile

        try:
            pkg = parse_runfile(repo&"/"&i)
        except CatchableError:
            raise

        let tarball = "kpkg-tarball-"&pkg.pkg&"-"&pkg.versionString&".tar.gz"
        let chksum = tarball&".sum"

        if fileExists("/var/cache/kpkg/archives/arch/"&hostCPU&"/"&tarball) and
                fileExists("/var/cache/kpkg/archives/arch/"&hostCPU&"/"&chksum):
            echo "Tarball already exists, not gonna download again"
        elif not offline:
            echo "Downloading tarball for "&i
            try:
                waitFor download("https://"&binrepo&"/arch/"&hostCPU&"/"&tarball,
                        "/var/cache/kpkg/archives/arch/"&hostCPU&"/"&tarball)
                echo "Downloading checksums for "&i
                waitFor download("https://"&binrepo&"/arch/"&hostCPU&"/"&chksum,
                        "/var/cache/kpkg/archives/arch/"&hostCPU&"/"&chksum)
                waitFor download("https://"&binrepo&"/arch/"&hostCPU&"/"&chksum&".bin",
                        "/var/cache/kpkg/archives/arch/"&hostCPU&"/"&chksum&".bin")

            except CatchableError:
                err("couldn't download tarball", false)
        else:
            err("attempted to download tarball from binary repository in offline mode", false)

    if not downloadOnly:
        for i in packages:
            repo = findPkgRepo(i)
            install_pkg(repo, i, root, true)
            echo "Installation for "&i&" complete"

proc install*(promptPackages: seq[string], root = "/", yes: bool = false,
        no: bool = false,
    binrepo = "mirror.kreato.dev", offline = false,
            downloadOnly = false): string =
    ## Download and install a package through a binary repository
    if promptPackages.len == 0:
        err("please enter a package name", false)

    if not isAdmin():
        err("you have to be root for this action.", false)

    var deps: seq[string]

    var packages = promptPackages

    try:
        deps = dephandler(packages)
    except CatchableError:
        raise


    echo "Packages: "&deps.join(" ")&" "&packages.join(" ")

    var output: string
    if yes:
        output = "y"
    elif no:
        output = "n"
    else:
        stdout.write "Do you want to continue? (y/N) "
        output = readLine(stdin)

    if output.toLower() != "y":
        return "kpkg: exiting"

    var depsDelete: string

    let fullRootPath = expandFilename(root)

    for i in deps:
        if dirExists(fullRootPath&"/var/cache/kpkg/installed/"&i):
            depsDelete = depsDelete&" "&i

    for i in depsDelete.split(" ").filterit(it.len != 0):
        deps.delete(deps.find(i))

    if not (deps.len == 0 and deps == @[""]):
        install_bin(deps, binrepo, fullRootPath, offline,
                downloadOnly = downloadOnly)

    install_bin(packages, binrepo, fullRootPath, offline,
            downloadOnly = downloadOnly)

    return "kpkg: done"