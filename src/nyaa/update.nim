proc update(repo = "https://github.com/kreatolinux/nyaa-repo.git",
    path = "/etc/nyaa"): string =
    ## Update repositories
    if dirExists(path):
        discard execProcess("git -C "&path&"pull")
    else:
        discard execProcess("git clone "&repo&" "&path)
        if repo in getConfigValue("Repositories", "RepoLinks") == false and path in getConfigValue("Repositories", "RepoDirs") == false:
          setConfigValue("Repositories", "RepoLinks", getConfigValue("Repositories", "RepoLinks")&" "&repo)
          setConfigValue("Repositories", "RepoDirs", getConfigValue("Repositories", "RepoDirs")&" "&path)

    result = "Updated all repositories."
