proc update(repo = "",
    path = "", branch = "master"): string =
    ## Update repositories

    if not isAdmin():
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
            if "::" in i.link:
                echo "nyaa: repository on "&i.dir&" not found, cloning them now..."
                discard execProcess("git clone "&i.link.split("::")[0]&" "&i.dir)
                setCurrentDir(i.dir)
                discard execProcess("git checkout "&i.link.split("::")[0])
            else:
                echo "nyaa: repository on "&i.dir&" not found, cloning them now..."
                discard execProcess("git clone "&i.link&" "&i.dir)

    if path != "" and repo != "":
        echo "cloning "&path&" from "&repo
        discard execProcess("git clone "&repo&" "&path)
        if not (repo in repolinks and path in repodirs):
            if branch != "master":
                setCurrentDir(path)
                discard execProcess("git checkout "&branch)
                setConfigValue("Repositories", "RepoLinks",
                        repolinks&" "&repo&"::"&branch)
                setConfigValue("Repositories", "RepoDirs", repodirs&" "&path)
            else:
                setConfigValue("Repositories", "RepoLinks", repolinks&" "&repo)
                setConfigValue("Repositories", "RepoDirs", repodirs&" "&path)


    return "nyaa: updated all repositories"
