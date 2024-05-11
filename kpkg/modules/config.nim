import parsecfg
import os
import logger
import streams
import strutils

const configPath = "/etc/kpkg/kpkg.conf"

var config {.threadvar.}: Config

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
  config.setSectionKey("Options", "cxx", "g++") # GCC works the best right now
  config.setSectionKey("Options", "ccache", "false")
  config.setSectionKey("Options", "verticalSummary", "false")
  config.setSectionKey("Options", "sourceMirror", "mirror.kreato.dev/sources")

  # [Repositories]
  config.setSectionKey("Repositories", "repoDirs",
      "/etc/kpkg/repos/main /etc/kpkg/repos/lockin") # Seperate by space
  config.setSectionKey("Repositories", "repoLinks",
      "https://github.com/kreatolinux/kpkg-repo.git::"&branch&" https://github.com/kreatolinux/kpkg-repo-lockin.git::"&branch) # Seperate by space, must match RepoDirs

  config.setSectionKey("Repositories", "binRepos",
      "mirror.kreato.dev") # Seperate by space
  
  # [Parallelization]
  config.setSectionKey("Parallelization", "threadsUsed", "1")

  # [Upgrade]
  config.setSectionKey("Upgrade", "buildByDefault", "yes") # Build packages by default
  # config.setSectionKey("Upgrade, "dontUpgrade", "") # kpkg wont touch this package, seperate by space

  config.writeConfig(configPath)

  return config


proc getConfigValue*(section: string, key: string, defaultVal = ""): string =
  ## Reads the configuration file and returns value of section.
  if not fileExists(configPath):
    config = initializeConfig()
  else:
    config = loadConfig(configPath)
  return config.getSectionValue(section, key, defaultVal)

proc getConfigSection*(section: string, defaultVal = ""): string =
  ## Reads the configuration file and returns value of section.
  if not fileExists(configPath):
    config = initializeConfig()
  else:
    config = loadConfig(configPath)

  var fileStr = newFileStream(configPath, fmRead)
  var parser: CfgParser
  var res: string
  var reachedSection = false

  open(parser, fileStr, configPath)
  while true:
    var entry = next(parser)

    if entry.kind == cfgEof: break

    if reachedSection:
        if entry.kind == cfgKeyValuePair:
            if isEmptyOrWhitespace(res):
                res = entry.key & "=" & entry.value
            else:
                res.add("\n" & entry.key & "=" & entry.value)
        else:
            break

    if entry.kind == cfgSectionStart and entry.section == section:
        reachedSection = true

  return res

proc setConfigValue*(section: string, key: string, value: string) =
  ## Writes a section to the configuration file.
  config.setSectionKey(section, key, value)
  config.writeConfig(configPath)

proc findPkgRepo*(package: string): string =
  ## finds the package repository.
  for i in getConfigValue("Repositories", "repoDirs").split(" "):
    if dirExists(i&"/"&package):
      return i
  # return blank line if not found
  return ""

proc returnConfig*(): string =
  ## Returns the full configuration file.
  if not fileExists(configPath):
    config = initializeConfig()
  else:
    config = loadConfig(configPath)
  
  echo ($config).strip()


if not fileExists(configPath):
  config = initializeConfig()
else:
  config = loadConfig(configPath)
