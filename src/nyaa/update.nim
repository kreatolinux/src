proc update(repo = "",
    path = ""): string =
    ## Update repositories

    if isAdmin() == false:
        err("you have to be root for this action.", false)

    let repodirs = getConfigValue("Repositories", "RepoDirs")
    let repolinks = getConfigValue("Repositories", "RepoLinks")

    let repoList: seq[tuple[dir: string, link: string]] = zip(repodirs.split(
            " "), repolinks.split(" "))

    for i in repoList:
        if dirExists(i.dir):
            if execShellCmd("git -C "&i.dir&" pull") != 0:
                err("failed to update repositories!", false)
        else:
            echo "nyaa: repository on "&i.dir&" not found, cloning them now..."
            discard execProcess("git clone "&i.link&" "&i.dir)

    if path != "" and repo != "":
        echo "cloning "&path&" from "&repo
        discard execProcess("git clone "&repo&" "&path)
        if not (repo in repolinks and path in repodirs):
            setConfigValue("Repositories", "RepoLinks", repolinks&" "&repo)
            setConfigValue("Repositories", "RepoDirs", repodirs&" "&path)


    return "nyaa: updated all repositories"
