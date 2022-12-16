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
          echo removeInternal(i, root)
    else:
      return "Exiting."
