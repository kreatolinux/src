import threadpool

proc install_pkg(repo: string, package: string, root: string, binary = false) =
    ## Installs an package.

    var pkg: runFile
    try:
        pkg = parse_runfile(repo&"/"&package)
    except:
        raise

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
        execProcess(
        "tar -hxvf"&tarball&" -C "&root))

proc install_bin(packages: seq[string], binrepo: string, root: string,
        offline: bool, downloadOnly = false) =
    ## Downloads and installs binaries.

    discard existsOrCreateDir("/var/cache/kpkg/archives")
    setCurrentDir("/var/cache/kpkg/archives")

    var repo: string

    for i in packages:
        repo = findPkgRepo(i)
        var pkg: runFile

        try:
            pkg = parse_runfile(repo&"/"&i)
        except:
            raise

        let tarball = "kpkg-tarball-"&pkg.pkg&"-"&pkg.versionString&".tar.gz"
        let chksum = tarball&".sum"

        if fileExists("/var/cache/kpkg/archives/"&hostCPU&"/"&tarball) and
                fileExists("/var/cache/kpkg/archives/"&hostCPU&"/"&chksum):
            echo "Tarball already exists, not gonna download again"
        elif not offline:
            echo "Downloading tarball for "&i
            try:
                discard spawn download("https://"&binrepo&"/arch/"&hostCPU&"/"&tarball, tarball)
                echo "Downloading tarball checksum for "&i
                discard spawn download("https://"&binrepo&"/arch/"&hostCPU&"/"&chksum, chksum)
            except:
                raise

            sync()
        else:
            err("attempted to download tarball from binary repository in offline mode", false)

    if not downloadOnly:
        for i in packages:
            repo = findPkgRepo(i)
            install_pkg(repo, i, root, true)
            echo "Installation for "&i&" complete"

proc install(promptPackages: seq[string], root = "/", yes: bool = false,
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
    var packages_bin = promptPackages
    # append bin suffix to packages
    for i, _ in promptPackages:
        packages_bin[i] = promptPackages[i]&"-bin"

    try:
        deps = dephandler(packages_bin)
    except:
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
