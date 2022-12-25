const configPath = "/etc/nyaa.conf"

var config: Config

proc initializeConfig(): Config =
  ## Initializes the configuration file

  if isAdmin() == false:
    err("please be root to initialize config", false)

  var config = newConfig()
  # [Options]
  config.setSectionKey("Options", "cc", "gcc") # GCC works the best right now
  
  # [Repositories]
  config.setSectionKey("Repositories", "RepoDirs",
      "/etc/nyaa /etc/nyaa-bin") # Seperate by space
  config.setSectionKey("Repositories", "RepoLinks",
      "https://github.com/kreatolinux/nyaa-repo.git https://github.com/kreatolinux/nyaa-repo-bin.git") # Seperate by space, must match RepoDirs

  # [Upgrade]
  config.setSectionKey("Upgrade", "buildByDefault", "yes") # Build packages by default
  # config.setSectionKey("Upgrade, "dontUpgrade", "") # Nyaa wont touch this package, seperate by space

  config.writeConfig(configPath)

proc getConfigValue(section: string, key: string): string =
  ## Reads the configuration file and returns value of section.
  return config.getSectionValue(section, key)

proc setConfigValue(section: string, key: string, value: string) =
  ## Writes a section to the configuration file.
  config.setSectionKey(section, key, value)
  config.writeConfig(configPath)

proc findPkgRepo(package: string): string =
  ## finds the package repository.
  for i in getConfigValue("Repositories", "RepoDirs").split(" "):
    if dirExists(i&"/"&package):
      return i
  # return blank line if not found
  return ""

if not fileExists(configPath):
  config = initializeConfig()
else:
  config = loadConfig(configPath)
