import osproc
import strutils
import libsha/sha256
include modules/dephandler
include modules/runparser
include modules/downloader
include install

const lockfile = "/tmp/nyaa.lock"

proc cleanUp() {.noconv.} =
    ## Cleans up.
    removeFile(lockfile)
    quit(0)

proc builder(repo: string, path: string, destdir: string,
    root = "/tmp/nyaa_build", srcdir = "/tmp/nyaa_srcdir") =
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

    for i in sources.split(";"):
        filename = extractFilename(i.replace("$VERSION", version))
        waitFor download(i.replace("$VERSION", version), filename)
        if sha256hexdigest(readAll(open(filename)))&"  "&filename != sha256sum:
            err "sha256sum doesn't match"
        if existsPrepare != 0:
            discard execProcess("bsdtar -xvf "&filename)

    if existsPrepare == 0:
        assert execShellCmd(". "&path&"/run"&" && prepare") == 0, "prepare failed"

    if execShellCmd(". "&path&"/run"&" && export DESTDIR="&root&" && export ROOT=$DESTDIR && build") != 0:
        err("nyaa: build failed")

    var tarball: string

    if epoch != "":
        tarball = "/etc/nyaa.tarballs/nyaa-tarball-"&pkg&"-"&version&"-"&release&"-"&epoch&".tar.gz"
    else:
        tarball = "/etc/nyaa.tarballs/nyaa-tarball-"&pkg&"-"&version&"-"&release&".tar.gz"

    discard execProcess("tar -czvf "&tarball&" -C "&root&" .")

    writeFile(tarball&".sum", sha256hexdigest(readAll(open(
        tarball)))&"  "&tarball)

    install_pkg(repo, pkg, destdir)

    removeFile(lockfile)

    removeDir(srcdir)
    removeDir(root)

proc build(no = false, yes = false, root = "/",
    packages: seq[string]): string =
    ## Build and install packages
    var deps: seq[string]
    var res: seq[string]
    var repo: string

    if packages.len == 0:
        err("nyaa: please enter a package name", false)

    try:
        deps = dephandler(packages, repo)
    except:
        raise

    echo "Packages: "&deps.join(" ")&" "&packages.join(" ")

    var output = ""
    if yes:
        output = "y"
    elif no:
        output = "n"

    if isEmptyOrWhitespace(output):
        stdout.write "Do you want to continue? (y/N) "
        output = readLine(stdin)

    if output.toLower() == "y":
        for i in deps:
            try:
                repo = findPkgRepo(i)
                if dirExists("/etc/nyaa.installed/"&i):
                    discard
                else:
                    builder(repo, repo&"/"&i, root)
                    echo("nyaa: built "&i&" successfully")
            except:
                raise

        for i in packages:
            try:
                repo = findPkgRepo(i)
                builder(repo, repo&"/"&i, root)
                echo("nyaa: built "&i&" successfully")
            except:
                raise
        return "nyaa: built all packages successfully"
    return "nyaa: exiting"
