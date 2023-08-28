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

proc ctrlc() {.noconv.} =
    for path in walkFiles("/var/cache/kpkg/archives/arch/"&hostCPU&"/*.partial"):
        removeFile(path)

    echo ""
    echo "kpkg: ctrl+c pressed, shutting down"
    quit(130)

setControlCHook(ctrlc)

proc install_pkg*(repo: string, package: string, root: string) =
    ## Installs an package.

    var pkg: runFile
    try:
        pkg = parse_runfile(repo&"/"&package)
    except CatchableError:
        raise

    for i in pkg.conflicts:
        if dirExists(root&"/var/cache/kpkg/installed/"&i):
            err(i&" conflicts with "&package)

    if dirExists(root&"/var/cache/kpkg/installed/"&package):

        echo "kpkg: package already installed, reinstalling"

        createDir("/tmp")
        createDir("/tmp/kpkg")
        createDir("/tmp/kpkg/reinstall")

        moveDir(root&"/var/cache/kpkg/installed/"&package,
                "/tmp/kpkg/reinstall/"&package&"-old")

    for i in pkg.replaces:
        if dirExists(root&"/var/cache/kpkg/installed/"&i) and expandSymlink(
                root&"/var/cache/kpkg/installed/"&i) != package:
            discard removeInternal(i, root)
            if not symlinkExists(root&"/var/cache/kpkg/installed/"&i):
                createSymlink(package, root&"/var/cache/kpkg/installed/"&i)

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

    writeFile(root&"/var/cache/kpkg/installed/"&package&"/list_files",
            execProcess("tar -tf"&tarball))

    discard execProcess("tar -hxf"&tarball&" -C "&root)

    # Run ldconfig afterwards for any new libraries
    discard execProcess("ldconfig")

    if dirExists("/tmp/kpkg/reinstall/"&package&"-old"):
        let cmd = execProcess("grep -xvFf /tmp/kpkg/reinstall/"&package&"-old/list_files /var/cache/kpkg/installed/"&package&"/list_files")
        writeFile("/tmp/kpkg/reinstall/list_files", cmd)
        discard removeInternal("reinstall", root, installedDir = "/tmp/kpkg",
                ignoreReplaces = true)
        removeDir("/tmp/kpkg")

    var existsPostinstall = execCmdEx(
            ". "&repo&"/"&package&"/run"&" && command -v postinstall").exitCode

    if existsPostinstall == 0:
        if execShellCmd(". "&repo&"/"&package&"/run"&" && postinstall") != 0:
            err("postinstall failed")

    for i in pkg.optdeps:
        echo i

proc down_bin(package: string, binrepos: seq[string], root: string, offline: bool) =
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
        offline: bool, downloadOnly = false) =
    ## Downloads and installs binaries.

    var repo: string

    for i in packages:
        if threadsUsed == 1:
          down_bin(i, binrepos, root, offline)
        else:
          spawn down_bin(i, binrepos, root, offline)

    if threadsUsed != 1:
        sync()

    if not downloadOnly:
        for i in packages:
            repo = findPkgRepo(i)
            install_pkg(repo, i, root)
            echo "Installation for "&i&" complete"

proc install*(promptPackages: seq[string], root = "/", yes: bool = false,
        no: bool = false,  offline = false, downloadOnly = false): string =
    ## Download and install a package through a binary repository
    if promptPackages.len == 0:
        err("please enter a package name", false)

    if not isAdmin():
        err("you have to be root for this action.", false)

    var deps: seq[string]

    var packages = promptPackages

    try:
        deps = dephandler(packages, root = root)
    except CatchableError:
        raise

    printReplacesPrompt(deps, root)
    printReplacesPrompt(packages, root)

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
    
    let binrepos = getConfigValue("Repositories", "binRepos").split(" ")

    if not (deps.len == 0 and deps == @[""]):
        install_bin(deps, binrepos, fullRootPath, offline,
                downloadOnly = downloadOnly)
        install_bin(packages, binrepos, fullRootPath, offline,
                downloadOnly = downloadOnly)

    return "kpkg: done"
