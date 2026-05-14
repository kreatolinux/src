import parsecfg
import os
import streams
import strutils
import regex
import ../../common/logging

const configPath = "/etc/kpkg/kpkg.conf"

var disableExcludes {.threadvar.}: bool
var cliExcludePatterns {.threadvar.}: seq[string]
var config {.threadvar.}: Config

const branch* {.strdefine.}: string = "stable"

proc createDefaultConfig(): Config =
  result = newConfig()
  # [Options]
  result.setSectionKey("Options", "cc", "gcc") # GCC works the best right now
  result.setSectionKey("Options", "cxx", "g++") # GCC works the best right now
  result.setSectionKey("Options", "ccache", "false")
  result.setSectionKey("Options", "verticalSummary", "false")
  result.setSectionKey("Options", "sourceMirror", "mirror.krea.to/sources")
  result.setSectionKey("Options", "excludePkgs", "")

  # [Repositories]
  result.setSectionKey("Repositories", "repoDirs",
      "/etc/kpkg/repos/main /etc/kpkg/repos/lockin") # Seperate by space
  result.setSectionKey("Repositories", "repoLinks",
      "https://github.com/kreatolinux/kpkg-repo.git::"&branch&" https://github.com/kreatolinux/kpkg-repo-lockin.git::"&branch) # Seperate by space, must match RepoDirs

  result.setSectionKey("Repositories", "binRepos",
      "mirror.krea.to") # Seperate by space
  
  # [Parallelization]
  result.setSectionKey("Parallelization", "threadsUsed", "1")

  # [Upgrade]
  result.setSectionKey("Upgrade", "buildByDefault", "yes") # Build packages by default

proc initializeConfig*(): Config =
  ## Initializes the configuration file
  var config = createDefaultConfig()

  if not isAdmin():
    return config

  discard existsOrCreateDir("/etc/kpkg")
  discard existsOrCreateDir("/etc/kpkg/repos")

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
  ## Reads the configuration file and returns the section as a string.
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

proc setDisableExcludes*(val: bool) =
  disableExcludes = val

proc getDisableExcludes*(): bool =
  return disableExcludes

proc addCliExcludePatterns*(patterns: seq[string]) =
  cliExcludePatterns = patterns

proc getCliExcludePatterns*(): seq[string] =
  return cliExcludePatterns

proc patternToRegex(pattern: string): Regex2 =
  if pattern.contains('(') or pattern.contains('|') or
     pattern.startsWith('^') or pattern.endsWith('$') or
     pattern.contains('+'):
    return re2(pattern)
  else:
    var regexStr = pattern
    for c in ['.', '+', '?', '[', ']', '{', '}', '|', '^', '$']:
      regexStr = regexStr.replace($c, "\\" & $c)
    regexStr = regexStr.replace("*", ".*")
    return re2("^" & regexStr & "$")

proc getExcludedPkgs*(repo: string = ""): seq[string] =
  result = @[]
  let globalExcludes = getConfigValue("Options", "excludePkgs").split(" ")
  for p in globalExcludes:
    if not isEmptyOrWhitespace(p):
      result.add(p)
  if not isEmptyOrWhitespace(repo):
    let repoExcludes = getConfigValue("Exclude:" & repo, "excludePkgs").split(" ")
    for p in repoExcludes:
      if not isEmptyOrWhitespace(p) and p notin result:
        result.add(p)
  if cliExcludePatterns.len > 0:
    for p in cliExcludePatterns:
      if not isEmptyOrWhitespace(p) and p notin result:
        result.add(p)

proc isExcluded*(package: string, repo: string = ""): bool =
  if disableExcludes:
    return false
  let patterns = getExcludedPkgs(repo)
  for pattern in patterns:
    if isEmptyOrWhitespace(pattern):
      continue
    try:
      if package.match(patternToRegex(pattern)):
        return true
    except CatchableError:
      warn "Invalid exclude pattern: " & pattern
  return false


if not fileExists(configPath):
  config = initializeConfig()
else:
  config = loadConfig(configPath)
