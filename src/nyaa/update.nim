proc update(repo = "https://github.com/kreatolinux/nyaa-repo.git",
    path = "/etc/nyaa"): string =
    ## Update repositories
    if dirExists(path):
        discard execProcess("git -C "&path&"pull")
    else:
        discard execProcess("git clone "&repo&" "&path)
        let repolinks = getConfigValue("Repositories", "RepoLinks")
        let repodirs = getConfigValue("Repositories", "RepoDirs")
        if not (repo in repolinks and path in repodirs):
          setConfigValue("Repositories", "RepoLinks", repolinks&" "&repo)
          setConfigValue("Repositories", "RepoDirs", repodirs&" "&path)

    result = "Updated all repositories."
