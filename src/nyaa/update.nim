proc update(repo = "https://github.com/kreatolinux/nyaa-repo.git",
    path = "/etc/nyaa"): string =
    ## Update repositories
    if dirExists(path):
        if execShellCmd("git -C "&path&"pull") != 0:
            err("nyaa: failed to update repositories!", false)
    else:
        echo "nyaa: repositories not found, cloning them now..."
        discard execProcess("git clone "&repo&" "&path)
        let repolinks = getConfigValue("Repositories", "RepoLinks")
        let repodirs = getConfigValue("Repositories", "RepoDirs")
        if not (repo in repolinks and path in repodirs):
            setConfigValue("Repositories", "RepoLinks", repolinks&" "&repo)
            setConfigValue("Repositories", "RepoDirs", repodirs&" "&path)

    return "nyaa: updated all repositories"
