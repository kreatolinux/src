import shadow
import parsecfg
import os
import logger
import strutils

const configPath = "/etc/kpkg/kpkg.conf"

var config: Config

const branch* {.strdefine.}: string = "stable"

proc initializeConfig*(): Config =
  ## Initializes the configuration file

  if not isAdmin():
    err("please be root to initialize config", false)

  discard existsOrCreateDir("/etc/kpkg")
  discard existsOrCreateDir("/etc/kpkg/repos")

  var config = newConfig()
  # [Options]
  config.setSectionKey("Options", "cc", "gcc") # GCC works the best right now
  
  # [Repositories]
  config.setSectionKey("Repositories", "RepoDirs",
      "/etc/kpkg/repos/main /etc/kpkg/repos/lockin") # Seperate by space
  config.setSectionKey("Repositories", "RepoLinks",
      "https://github.com/kreatolinux/kpkg-repo.git::"&branch&" https://github.com/kreatolinux/kpkg-repo-lockin.git::"&branch) # Seperate by space, must match RepoDirs

  # [Upgrade]
  config.setSectionKey("Upgrade", "buildByDefault", "yes") # Build packages by default
  # config.setSectionKey("Upgrade, "dontUpgrade", "") # Nyaa wont touch this package, seperate by space

  config.writeConfig(configPath)

  # Add an _kpkg user if it doesn't exist
  if not existsUser("_kpkg"):
    if addUser("_kpkg") == false:
      err("adding user _kpkg failed!")

  return config


proc getConfigValue*(section: string, key: string): string =
  ## Reads the configuration file and returns value of section.
  return config.getSectionValue(section, key)

proc setConfigValue*(section: string, key: string, value: string) =
  ## Writes a section to the configuration file.
  config.setSectionKey(section, key, value)
  config.writeConfig(configPath)

proc findPkgRepo*(package: string): string =
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
