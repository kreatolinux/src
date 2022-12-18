proc remove(packages: seq[string], yes = false, root = ""): string =
    ## Remove packages

    # bail early if user isn't admin
    if not isAdmin():
        err("you have to be root for this action.", false)

    if packages.len == 0:
        err("please enter a package name", false)

    var output: string

    if not yes:
        echo "Removing: "&packages.join(" ")
        stdout.write "Do you want to continue? (y/N) "
        output = readLine(stdin)
    else:
        output = "y"

    if output.toLower() == "y":
        for i in packages:
            echo removeInternal(i, root)
        return "nyaa: done!"

    return "nyaa: exiting"
