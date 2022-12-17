proc initializeConfig(configpath = "/etc/nyaa.conf") =
  ## Initializes the configuration file

  if fileExists(configpath):
    discard

  if isAdmin() == false:
    err("nyaa: please be root to initialize config", false)

  var dict = newConfig()
  # [Options]
  dict.setSectionKey("Options", "cc", "gcc") # GCC works the best right now
  
  # [Repositories]
  dict.setSectionKey("Repositories", "RepoDirs",
      "/etc/nyaa /etc/nyaa-bin") # Seperate by space
  dict.setSectionKey("Repositories", "RepoLinks",
      "https://github.com/kreatolinux/nyaa-repo.git https://github.com/kreatolinux/nyaa-repo-bin.git") # Seperate by space, must match RepoDirs

  # [Upgrade]
  dict.setSectionKey("Upgrade", "buildByDefault", "yes") # Build packages by default
  #dict.setSectionKey("Upgrade, "dontUpgrade", "") # Nyaa wont touch this package, seperate by space

  dict.writeConfig(configpath)

proc getConfigValue(section: string, key: string,
    configpath = "/etc/nyaa.conf"): string =
  ## Reads the configuration file and returns value of section.
  let dict = loadConfig(configpath)
  return dict.getSectionValue(section, key)

proc setConfigValue(section: string, key: string, value: string,
    configpath = "/etc/nyaa.conf") =
  ## Writes a section to the configuration file.
  var dict = loadConfig(configpath)
  dict.setSectionKey(section, key, value)
  dict.writeConfig(configpath)

proc findPkgRepo(package: string, conf = "/etc/nyaa.conf"): string =
  ## finds the package repository.
  for i in getConfigValue("Repositories", "RepoDirs").split(" "):
    if dirExists(i&"/"&package):
      return i
  # return blank line if not found
  return ""
