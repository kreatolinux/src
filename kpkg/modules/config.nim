import parsecfg
import os
import strutils
import regex
import tables
import ../../common/logging

# Compile-time override permits isolated configuration tests and custom builds.
const kpkgConfigPath* {.strdefine.} = "/etc/kpkg/kpkg.conf"
const configPath = kpkgConfigPath

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
  result.setSectionKey("Parallelization", "threadsUsed", "4")
  result.setSectionKey("Parallelization", "downloadThreads", "8")
  result.setSectionKey("Parallelization", "installThreads", "4")

  # [Upgrade]
  result.setSectionKey("Upgrade", "buildByDefault", "yes") # Build packages by default

  # [Telemetry]
  result.setSectionKey("Telemetry", "enabled", "false")
  result.setSectionKey("Telemetry", "endpoint", "localhost:4317")
  result.setSectionKey("Telemetry", "tls", "false")
  result.setSectionKey("Telemetry", "timeoutMs", "5000")
  result.setSectionKey("Telemetry", "failurePolicy", "continue")
  result.setSectionKey("Telemetry", "authType", "none")
  result.setSectionKey("Telemetry", "username", "")
  result.setSectionKey("Telemetry", "password", "")
  result.setSectionKey("Telemetry", "bearerToken", "")

proc protectConfigFile*(path: string) =
  setFilePermissions(path, {fpUserRead, fpUserWrite})

proc initializeConfig*(): Config =
  ## Initializes the configuration file
  var config = createDefaultConfig()

  if not isAdmin():
    return config

  createDir(parentDir(configPath))
  createDir(parentDir(configPath) / "repos")

  config.writeConfig(configPath)
  protectConfigFile(configPath)

  return config


proc loadActiveConfig() =
  ## Only explicit configuration access may read or create the file.
  if not fileExists(configPath):
    config = initializeConfig()
  else:
    config = loadConfig(configPath)

proc ensureConfigLoaded() =
  if config.isNil:
    loadActiveConfig()

proc getConfigValue*(section: string, key: string, defaultVal = ""): string =
  ## Reads the configuration file and returns value of section.
  # Retain the existing refresh-on-read behavior.
  loadActiveConfig()
  return config.getSectionValue(section, key, defaultVal)

proc getThreadsUsed*(): int =
  ## Returns the number of threads to use for parallel operations
  ## (downloads, installs). Read from [Parallelization] threadsUsed.
  ## Values <= 1 disable parallelism; an unset/invalid value falls back to 4
  ## (capped at 16).
  let val = getConfigValue("Parallelization", "threadsUsed", "")
  try:
    let n = parseInt(val.strip())
    if n <= 1:
      return 1
    return min(n, 16)
  except CatchableError:
    discard
  # Fallback: default to 4 workers
  return 4

proc getDownloadThreads*(): int =
  ## Network transfers benefit from a wider pool than archive/database work.
  ## Explicit downloadThreads wins; legacy threadsUsed=1 still disables
  ## concurrency, while other legacy configurations default to at least 8.
  let explicit = getConfigValue("Parallelization", "downloadThreads", "")
  if not isEmptyOrWhitespace(explicit):
    try:
      return max(1, min(parseInt(explicit.strip()), 16))
    except CatchableError:
      discard
  let legacy = getThreadsUsed()
  if legacy <= 1:
    return 1
  return min(16, max(8, legacy))

proc getInstallThreads*(): int =
  let explicit = getConfigValue("Parallelization", "installThreads", "")
  if not isEmptyOrWhitespace(explicit):
    try:
      return max(1, min(parseInt(explicit.strip()), 16))
    except CatchableError:
      discard
  return getThreadsUsed()

proc getConfigSection*(section: string, defaultVal = ""): string =
  ## Reads the configuration file and returns the section as a string.
  loadActiveConfig()
  # Use the loaded config, which also works with in-memory defaults when an
  # unprivileged caller has no configuration file.
  if config.hasKey(section):
    for key, value in config[section].pairs:
      if result.len > 0:
        result.add("\n")
      result.add(key & "=" & value)

proc configSectionNames*(): seq[string] =
  ## Return sections from the active configuration, including custom sections.
  ensureConfigLoaded()
  for section in config.sections:
    result.add(section)

proc configKeyNames*(section: string): seq[string] =
  ## Return keys from the active configuration section.
  ensureConfigLoaded()
  if config.hasKey(section):
    for key in config[section].keys:
      result.add(key)

proc setConfigValue*(section: string, key: string, value: string) =
  ## Writes a section to the configuration file.
  ensureConfigLoaded()
  config.setSectionKey(section, key, value)
  config.writeConfig(configPath)
  protectConfigFile(configPath)

proc findPkgRepo*(package: string): string =
  ## finds the package repository.
  for i in getConfigValue("Repositories", "repoDirs").split(" "):
    if dirExists(i&"/"&package):
      return i
  # return blank line if not found
  return ""

proc redactTelemetrySecrets*(configOutput: string): string =
  var inTelemetrySection = false
  for line in configOutput.splitLines():
    let stripped = line.strip()
    if stripped.startsWith("[") and stripped.endsWith("]"):
      inTelemetrySection = stripped.toLowerAscii() == "[telemetry]"
    let separator = stripped.find('=')
    let key = if separator >= 0: stripped[0 ..< separator].strip().toLowerAscii() else: ""
    if inTelemetrySection and key in ["password", "bearertoken"] and
        separator >= 0:
      let originalSeparator = line.find('=')
      var valueStart = originalSeparator + 1
      while valueStart < line.len and line[valueStart] in {' ', '\t'}:
        inc valueStart
      let whitespace = line[originalSeparator + 1 ..< valueStart]
      result.add(line[0 .. originalSeparator] & whitespace & "REDACTED")
    else:
      result.add(line)
    result.add("\n")
  result = result.strip(leading = false, trailing = true)

proc returnConfig*(): string =
  ## Returns the full configuration file.
  loadActiveConfig()

  echo redactTelemetrySecrets(($config).strip())

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
