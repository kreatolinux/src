proc update(repo = "",
    path = ""): string =
    ## Update repositories

    if isAdmin() == false:
        err("you have to be root for this action.", false)

    let repodirs = getConfigValue("Repositories", "RepoDirs")
    let repolinks = getConfigValue("Repositories", "RepoLinks")

    for i in repodirs.split(" "):
        if dirExists(i):
            if execShellCmd("git -C "&i&" pull") != 0:
                err("failed to update repositories!", false)
        else:
            echo "nyaa: repository on "&i&" not found, cloning them now..."
            for l in repolinks.split(" "):
                discard execProcess("git clone "&l&" "&i)

    if path != "" and repo != "":
        echo "cloning "&path&" from "&repo
        discard execProcess("git clone "&repo&" "&path)
        if not (repo in repolinks and path in repodirs):
            setConfigValue("Repositories", "RepoLinks", repolinks&" "&repo)
            setConfigValue("Repositories", "RepoDirs", repodirs&" "&path)


    return "nyaa: updated all repositories"
