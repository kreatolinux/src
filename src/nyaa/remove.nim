proc remove(packages: seq[string], yes = false, root = ""): string =
    ## Remove packages
    if packages.len == 0:
        err("please enter a package name", false)

    var output: string

    if yes != true:
        echo "Removing: "&packages.join(" ")
        stdout.write "Do you want to continue? (y/N) "
        output = readLine(stdin)

    if output.toLower() == "y" or yes == true:

        if isAdmin() == false:
          err("you have to be root for this action.", false)

        for i in packages:
            if not fileExists("/etc/nyaa.installed/"&i&"/list_files"):
                err("package "&i&" is not installed", false)

            for line in lines "/etc/nyaa.installed/"&i&"/list_files":
                # TODO: replace this with a Nim implementation
                discard execShellCmd("rm -f "&root&"/"&line&" 2>/dev/null")
                discard execShellCmd("[ -z \"$(ls -A "&root&"/"&line&" 2>/dev/null)\" ] && rm -rf "&root&"/"&line&" 2>/dev/null")
            removeDir("/etc/nyaa.installed/"&i)
            return "Package "&i&" removed."

    return "Exiting."
