proc info(repo = "/etc/nyaa", package: seq[string]): string =
    ## Get information about packages

    if package.len == 0:
        err("Please enter a package name", false)

    if not dirExists(repo&"/"&package[0]):
        err("Package "&pkg&" doesn't exist", false)

    parse_runfile(repo&"/"&package[0])

    echo "package name: "&pkg
    echo "package version: "&version
    echo "package release: "&release
    when declared(epoch):
        echo "package epoch: "&epoch
    if dirExists("/etc/nyaa.installed/"&package[0]):
        return "installed: yes"
    return "installed: no"

