proc install_pkg(repo: string, package: string, root: string, binary = false) =
    ## Installs an package.

    var tarball: string

    if epoch != "":
        tarball = "/etc/nyaa.tarballs/nyaa-tarball-"&pkg&"-"&version&"-"&release&"-"&epoch&".tar.gz"
    else:
        tarball = "/etc/nyaa.tarballs/nyaa-tarball-"&pkg&"-"&version&"-"&release&".tar.gz"

    if sha256hexdigest(readAll(open(tarball)))&"  "&tarball != readAll(open(
        tarball&".sum")):
        err("sha256sum doesn't match", false)

    setCurrentDir("/etc/nyaa.tarballs")

    if binary:
        parse_runfile(repo&"/"&package&"-bin")
    else:
        parse_runfile(repo&"/"&package)

    discard existsOrCreateDir("/etc/nyaa.installed")
    removeDir("/etc/nyaa.installed/"&package)
    copyDir(repo&"/"&package, "/etc/nyaa.installed/"&package)

    writeFile("/etc/nyaa.installed/"&package&"/list_files", execProcess(
        "tar -xvf"&tarball&" -C "&root))

proc install_bin(package: string, binrepo: string, root: string): string =
    ## Downloads and installs a binary.
    var repo = findPkgRepo(package&"-bin")
    parse_runfile(repo&"/"&package&"-bin")
    discard existsOrCreateDir("/etc/nyaa.tarballs")
    let tarball = "nyaa-tarball-"&package&"-"&version&"-"&release&".tar.gz"
    let chksum = tarball&".sum"
    setCurrentDir("/etc/nyaa.tarballs")
    echo "Downloading tarball"
    waitFor download("https://"&binrepo&"/"&tarball, tarball)
    echo "Downloading tarball checksum"
    waitFor download("https://"&binrepo&"/"&chksum, chksum)
    install_pkg(repo, package, root, true)
    return "Installation for "&package&" complete"


proc install(packages: seq[string], root = "/", yes = false, no = false,
    binrepo = "mirror.kreato.dev"): string =
    ## Download and install a package through a binary repository
    if packages.len == 0:
        err("please enter a package name", false)

    if isAdmin() == false:
        err("you have to be root for this action.", false)

    var deps: seq[string]
    var res: string
    var repo: string

    for i in packages:
        repo = findPkgRepo(i&"-bin")
        if repo == "":
            err("package "&i&" doesn't exist", false)
        deps = deduplicate(deps&dephandler(i&"-bin", repo).split(" "))
        res = res & deps.join(" ") & " " & i


    echo "Packages:"&res

    var output: string

    if yes != true and no != true:
        stdout.write "Do you want to continue? (y/N) "
        output = readLine(stdin)

    if output.toLower() != "y" and yes != true:
        return "nyaa: exiting"

    for i in deps:
        if dirExists("/etc/nyaa.installed/"&i):
            discard
        else:
            echo install_bin(i, binrepo, root)

    for i in packages:
        echo install_bin(i, binrepo, root)

    echo "nyaa: done"
