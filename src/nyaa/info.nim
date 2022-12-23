proc info(repo = "/etc/nyaa", package: seq[string]): string =
    ## Get information about packages

    if package.len == 0:
        err("Please enter a package name", false)

    if not dirExists(repo&"/"&package[0]):
        err("Package "&package[0]&" doesn't exist", false)

    var pkg: runFile
    try:
        pkg = parse_runfile(repo&"/"&package[0])
    except:
        raise

    echo "package name: "&pkg.pkg
    echo "package version: "&pkg.version
    echo "package release: "&pkg.release
    when declared(pkg.epoch):
        echo "package epoch: "&pkg.epoch
    if dirExists("/etc/nyaa.installed/"&pkg.pkg):
        return "installed: yes"
    # return err if package isn't installed (for scripting :p)
    err("installed: no", false)
