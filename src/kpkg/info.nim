proc info(package: seq[string], testing = false): string =
    ## Get information about packages

    if package.len == 0:
        err("Please enter a package name", false)

    let repo = findPkgRepo(package[0])

    if not dirExists(repo&"/"&package[0]):
        err("Package "&package[0]&" doesn't exist", false)

    var pkg: runFile
    try:
        pkg = parse_runfile(repo&"/"&package[0])
    except CatchableError:
        raise

    echo "package name: "&pkg.pkg
    echo "package version: "&pkg.version
    echo "package release: "&pkg.release
    when declared(pkg.epoch):
        echo "package epoch: "&pkg.epoch
    if dirExists("/var/cache/kpkg/installed/"&pkg.pkg):
        return "installed: yes"

    # don't error when package isn't installed during testing
    const ret = "installed: no"
    if testing:
        return ret

    # return err if package isn't installed (for scripting :p)
    err(ret, false)
