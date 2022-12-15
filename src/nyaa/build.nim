import os
import osproc
import strutils
import libsha/sha256
include modules/dephandler
include modules/runparser
include modules/logger
include install

const lockfile = "/tmp/nyaa.lock"

proc cleanUp() {.noconv.} =
    ## Cleans up.
    echo "nyaa: removing lockfile"
    removeFile(lockfile)
    quit(0)

proc builder(repo: string, path: string, destdir: string,
    root = "/tmp/nyaa_build", srcdir = "/tmp/nyaa_srcdir"): string =
    ## Builds the packages.

    if isAdmin() == false:
        err("you have to be root for this action.", false)

    if fileExists(lockfile):
        err("lockfile exists, will not proceed", false)

    echo "nyaa: starting build"

    writeFile(lockfile, "") # Create lockfile

    setControlCHook(cleanUp)

    # Actual building start here

    # Remove directories if they exist
    removeDir(root)
    removeDir(srcdir)

    # Create tarball directory if it doesn't exist
    discard existsOrCreateDir("/etc/nyaa.tarballs")

    # Create required directories
    createDir(root)
    createDir(srcdir)

    # Enter into the source directory
    setCurrentDir(srcdir)

    parse_runfile(path)

    var filename: string
    var existsPrepare = execShellCmd(". "&path&"/run"&" && command -v prepare")

    var client = newHttpClient()

    for i in sources.split(";"):
        filename = extractFilename(i.replace("$VERSION", version))
        writeFile(filename, client.getContent(i.replace("$VERSION", version)))
        if sha256hexdigest(readAll(open(filename)))&"  "&filename != sha256sum:
            err "sha256sum doesn't match"
        if existsPrepare != 0:
            discard execProcess("bsdtar -xvf "&filename)

    if existsPrepare == 0:
        assert execShellCmd(". "&path&"/run"&" && prepare") == 0, "prepare failed"

    if execShellCmd(". "&path&"/run"&" && export DESTDIR="&root&" && export ROOT=$DESTDIR && build") != 0:
      err("build failed")

    var tarball: string

    when declared(epoch):
        tarball = "/etc/nyaa.tarballs/nyaa-tarball-"&pkg&"-"&version&"-"&release&"-"&epoch&".tar.gz"
    else:
        tarball = "/etc/nyaa.tarballs/nyaa-tarball-"&pkg&"-"&version&"-"&release&".tar.gz"

    discard execProcess("tar -czvf "&tarball&" -C "&root&" .")

    writeFile(tarball&".sum", sha256hexdigest(readAll(open(
        tarball)))&"  "&tarball)

    install_pkg(repo, pkg, destdir)

    cleanUp()

    removeDir(srcdir)
    removeDir(root)

    return "nyaa: build complete"


proc build(repo = "/etc/nyaa", no = false, yes = false, destdir = "/",
    packages: seq[string]): string =
    ## Build and install packages
    var deps: seq[string]
    var res: string

    if packages.len == 0:
        err("please enter a package name", false)

    for i in packages:
        if not dirExists(repo&"/"&i):
            err("package `"&i&"` does not exist", false)
        deps = deduplicate(dephandler(i, repo).split(" "))
        res = res & deps.join(" ") & " " & i

    echo "Packages:"&res

    var output = ""
    if yes:
        output = "y"
    elif no:
        output = "n"

    if isEmptyOrWhitespace(output):
        stdout.write "Do you want to continue? (y/N) "
        output = readLine(stdin)

    if output.toLower() == "y":
        for i in packages:
            try:
                builder(repo, repo&"/"&i, destdir)
            except:
                raise

    return "nyaa: exiting"

