proc initializeConfig(configpath="/etc/nyaa.conf") =
  ## Initializes the configuration file
  
  if fileExists(configpath):
    discard

  if isAdmin() == false:
    err("Please be root to initialize config", false)

  var dict = newConfig()
  # [Options]
  dict.setSectionKey("Options", "cc", "gcc") # GCC works the best right now
  
  # [Repositories]
  dict.setSectionKey("Repositories", "RepoDirs", "/etc/nyaa") # Seperate by space
  dict.setSectionKey("Repositories", "RepoLinks", "https://github.com/kreatolinux/nyaa-repo.git") # Seperate by space, must match RepoDirs

  # [Upgrade]
  dict.setSectionKey("Upgrade", "buildByDefault", "yes") # Build packages by default
  #dict.setSectionKey("Upgrade, "dontUpgrade", "") # Nyaa wont touch this package, seperate by space
  
  dict.writeConfig(configpath)

proc findPkgRepo(package: string, conf = "/etc/nyaa.conf"): string =
  ## finds the package repository.
  let dict = loadConfig(conf)
  for i in dict.getSectionValue("Repositories", "RepoDirs").split(" "):
    if dirExists(i&"/"&package):
      return i
