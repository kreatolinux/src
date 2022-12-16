proc update(repo = "https://github.com/kreatolinux/nyaa-repo.git",
    path = "/etc/nyaa"): string =
    ## Update repositories
    if dirExists(path):
        discard execProcess("git -C "&path&"pull")
    else:
        discard execProcess("git clone "&repo&" "&path)
        var conf = loadConfig("/etc/nyaa.conf")
        if repo in conf.getSectionValue("Repositories", "RepoLinks") == false and path in conf.getSectionValue("Repositories", "RepoDirs") == false:
          conf.setSectionKey("Repositories", "RepoLinks", conf.getSectionValue("Repositories", "RepoLinks")&" "&repo)
          conf.setSectionKey("Repositories", "RepoDirs", conf.getSectionValue("Repositories", "RepoDirs")&" "&path)
          conf.writeConfig("/etc/nyaa.conf")

    result = "Updated all repositories."
