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

proc builder(package: string, destdir: string,
    root = "/tmp/nyaa_build", srcdir = "/tmp/nyaa_srcdir", offline = true,
            dontInstall = false, useCacheIfAvailable = false): bool =
    ## Builds the packages.

    if isAdmin() == false:
        err("you have to be root for this action.", false)

    if fileExists(lockfile):
        err("lockfile exists, will not proceed", false)

    echo "nyaa: starting build for "&package

    writeFile(lockfile, "") # Create lockfile

    setControlCHook(cleanUp)

    # Actual building start here

    var repo = findPkgRepo(package)

    var path = repo&"/"&package

    # Remove directories if they exist
    removeDir(root)
    removeDir(srcdir)

    # Create tarball directory if it doesn't exist
    discard existsOrCreateDir("/etc/nyaa.tarballs")

    # Create required directories
    createDir(root)
    createDir(srcdir)

    setFilePermissions(root, {fpOthersWrite, fpOthersRead, fpOthersExec})
    setFilePermissions(srcdir, {fpOthersWrite, fpOthersRead, fpOthersExec})

    # Enter into the source directory
    setCurrentDir(srcdir)

    var pkg: runFile
    try:
        pkg = parse_runfile(path)
    except:
        raise

    if fileExists("/etc/nyaa.tarballs/nyaa-tarball-"&pkg.pkg&"-"&pkg.versionString&".tar.gz") and
            fileExists(
            "/etc/nyaa.tarballs/nyaa-tarball-"&pkg.pkg&"-"&pkg.versionString&".tar.gz.sum") and
            useCacheIfAvailable == true and dontInstall == false:
        install_pkg(repo, package, destdir)
        removeFile(lockfile)
        return true

    var filename: string
    var existsPrepare = execShellCmd(". "&path&"/run"&" && command -v prepare")

    var int = 0

    for i in pkg.sources.split(";"):
        if i == "":
            continue
        filename = extractFilename(i.replace("$VERSION", pkg.version)).strip()
        try:
            waitFor download(i.replace("$VERSION", pkg.version), filename)
        except:
            raise

        var actualDigest = sha256hexdigest(readAll(open(
                filename)))&"  "&filename
        var expectedDigest = pkg.sha256sum.split(";")[int]
        if expectedDigest != actualDigest:
            err "sha256sum doesn't match for "&i&"\nExpected: "&expectedDigest&"\nActual: "&actualDigest

        int = int+1

        if existsPrepare != 0:
            discard execProcess("bsdtar -xvf "&filename)

    if existsPrepare == 0:
        assert execShellCmd(". "&path&"/run"&" && prepare") == 0, "prepare failed"

    var cmd = "su -s /bin/sh _nyaa -c '. "&path&"/run"&" && export CC="&getConfigValue(
            "Options",
            "cc")&" && export DESTDIR="&root&" && export ROOT=$DESTDIR && build'"

    if offline == true:
        cmd = "unshare -n /bin/sh -c '"&cmd&"'"

    if execShellCmd(cmd) != 0:
        err("build failed")

    let tarball = "/etc/nyaa.tarballs/nyaa-tarball-"&pkg.pkg&"-"&pkg.versionString&".tar.gz"

    discard execProcess("tar -czvf "&tarball&" -C "&root&" .")

    writeFile(tarball&".sum", sha256hexdigest(readAll(open(
        tarball)))&"  "&tarball)


    # Install package to root aswell so dependency errors doesnt happen
    # because the dep is installed to destdir but not root.
    if destdir != "/" and not dirExists("/etc/nyaa.installed/"&package) and
            dontInstall == false:
        install_pkg(repo, package, "/")

    if dontInstall == false:
        install_pkg(repo, package, destdir)

    removeFile(lockfile)

    removeDir(srcdir)
    removeDir(root)

    return false

proc build(no = false, yes = false, root = "/",
    packages: seq[string],
            useCacheIfAvailable = false): string =
    ## Build and install packages
    var deps: seq[string]

    if packages.len == 0:
        err("please enter a package name", false)

    try:
        deps = dephandler(packages)
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
        var cacheAvailable: string
        var builderOutput: bool
        for i in deps:
            try:
                if dirExists(root&"/etc/nyaa.installed/"&i):
                    discard
                else:
                    builderOutput = builder(i, root, offline = false,
                            useCacheIfAvailable = useCacheIfAvailable)

                    if builderOutput == false:
                        cacheAvailable = "false"

                    echo("nyaa: installed "&i&" successfully")

            except:
                raise

        if isEmptyOrWhitespace(cacheAvailable) and useCacheIfAvailable == true:
            cacheAvailable = "true"
        else:
            cacheAvailable = "false"

        for i in packages:
            try:
                discard builder(i, root, offline = false,
                            useCacheIfAvailable = parseBool(cacheAvailable))
                echo("nyaa: installed "&i&" successfully")

            except:
                raise
        return "nyaa: built all packages successfully"
    return "nyaa: exiting"
