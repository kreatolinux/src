import os
import posix
import sqlite
import config
import ../../common/logging
import strutils
import sequtils
import parsecfg
import runparser
import posix_utils
import gitutils

proc isEmptyDir(dir: string): bool =
  # Checks if a directory is empty or not.
  return toSeq(walkdir dir).len == 0

proc getDependents*(packages: seq[string], root = "/",
        addIfOutdated = true): seq[string] =
  # Gets dependents of a package
  # Eg. getDependents("neofetch") will return
  # @["bash"]
  var res: seq[string]

  for p in getListPackages():

    if not dirExists(p):
      continue

    let pkg = getPackage(p, root)

    for package in packages:
      if package in pkg.deps.split("!!k!!"):
        if addIfOutdated:
          let packageLocalVer = pkg.version
          let packageUpstreamVer = parseRunfile(findPkgRepo(
                  package)&"/"&package).versionString
          if packageLocalVer != packageUpstreamVer:
            res = res&p
          else:
            continue
        else:
          res = res&p

  return res


proc getRuntimeDependents*(packages: seq[string], root: string): seq[string] =
  ## Gets packages that have runtime dependencies on the given packages
  ## Eg. getRuntimeDependents("perl") will return packages that depend on perl at runtime
  var res: seq[string]

  for p in getListPackages():

    if not dirExists(p):
      continue

    let pkg = getPackage(p, root)

    for package in packages:
      if package in pkg.deps.split("!!k!!"):
        res = res&p

  return res


proc copyFileWithPermissionsAndOwnership*(source, dest: string, options = {
        cfSymlinkAsIs}) =
  ## Copies a file with both permissions and ownership.

  if dirExists(source) and not symlinkExists(source):
    debug "\""&source&"\" is a dir (and not a symlink), just going to ignore"
    debug "this shouldn't happen"
    return

  # Return early if dest is a dir
  if dirExists(dest):
    #debug "\""&dest&"\" is a directory, cant use copyFileWithPermissionsAndOwnership"
    return

  #debug "removing \""&dest&"\""
  removeFile(dest)

  if symlinkExists(source):
    #debug "overwriting \""&dest&"\" with the symlink at \""&source&"\""
    copyFile(source, dest, options = {cfSymlinkAsIs})
    return

  var statVar: Stat
  assert stat(source, statVar) == 0

  try:
    copyFileWithPermissions(source, dest, options = options)
    #debug "copyFileWithPermissions successful, setting chown"
    assert posix.chown(dest, statVar.st_uid, statVar.st_gid) == 0
  except Exception:
    debug "fatal, source: \""&source&"\", dest: \""&dest&"\""
    raise getCurrentException()

proc createDirWithPermissionsAndOwnership*(source, dest: string,
        followSymlinks = true) =

  if fileExists(dest) or symlinkExists(dest):
    #debug "\""&dest&"\" is a file/symlink, returning early"
    return

  if isEmptyDir(dest):
    #debug "\""&dest&"\" is empty, just going to overwrite"
    #debug "removing directory \""&dest&"\""
    removeDir(dest)
  else:
    return

  var statVar: Stat
  assert stat(source, statVar) == 0
  createDir(dest)
  #debug "createDir successful, setting chown and chmod"
  assert posix.chown(dest, statVar.st_uid, statVar.st_gid) == 0
  #debug "chown successful, setting permissions"
  setFilePermissions(dest, getFilePermissions(source), followSymlinks)

proc getInit*(root: string): string =
  ## Returns the init system.
  try:
    return loadConfig(root&"/etc/kreato-release").getSectionValue("Core", "init")
  except CatchableError:
    fatal("couldn't load "&root&"/etc/kreato-release")

proc getLibc*(root: string): string =
  ## Returns the libc.
  try:
    return loadConfig(root&"/etc/kreato-release").getSectionValue("Core", "libc")
  except CatchableError:
    fatal("couldn't load "&root&"/etc/kreato-release")

proc systemTarget*(root: string): string =
  ## Returns the system target.
  var target = uname().machine&"-linux"

  case getLibc(root):
    of "glibc":
      target = target&"-gnu"
    of "musl":
      target = target&"-musl"

  return target


proc kpkgTarget*(root: string, customTarget = ""): string =
  ## Returns the kpkg target.
  let conf = loadConfig(root&"/etc/kreato-release")
  var system: string
  if not isEmptyOrWhitespace(customTarget):
    system = customTarget
  else:
    system = systemTarget(root)

  return system&"-"&conf.getSectionValue("Core",
          "init")&"-"&conf.getSectionValue("Core", "tlsLibrary")

proc green*(s: string): string = "\e[32m" & s & "\e[0m"
proc blue*(s: string): string = "\e[34m" & s & "\e[0m"

proc appendInternal(f: string, t: string): string =
  # convenience proc to append.
  if isEmptyOrWhitespace(t):
    return f
  else:
    return t&" "&f

proc parsePkgInfo*(pkg: string): tuple[name: string, repo: string,
        version: string, commit: string, nameWithRepo: string] =
  ## Returns the package name, repo, version, commit and nameWithRepo.
  ## Version is empty when not specified.
  ## Commit is empty when not specified, or when the suffix is a version (not a commit hash).
  ## nameWithRepo outputs something like main/kpkg if the pkg includes the repo. It outputs the name if it doesn't.
  ##
  ## The '#' suffix is interpreted as:
  ## - A commit hash if it's a 4-40 character hex string (e.g., "e24958", "abc123def")
  ## - A version string otherwise (e.g., "v7.0.0-alpha2", "1.2.3")
  var name: string
  var repo: string
  var version: string
  var commit: string
  var nameWithRepo: string

  let pkgSplitVer = pkg.split("#")
  let pkgSplit = pkg.split("/")

  if pkgSplitVer.len > 1:
    let suffix = pkgSplitVer[1]

    # Determine if suffix is a commit hash or a version
    # Commit hashes are 4-40 character hex strings
    if isCommitHash(suffix):
      commit = suffix
      version = ""
    else:
      version = suffix
      commit = ""

    if pkgSplit.len > 1:
      name = pkgSplitVer[0].split("/")[1]
      repo = "/etc/kpkg/repos/"&pkgSplitVer[0].split("/")[0]
      nameWithRepo = pkgSplitVer[0]
    else:
      name = pkgSplitVer[0]
      repo = findPkgRepo(pkgSplitVer[0])

  else:
    version = ""
    commit = ""


  if pkgSplit.len > 1 and version == "" and commit == "":
    repo = "/etc/kpkg/repos/"&pkgSplit[0]
    name = pkgSplit[1]
    nameWithRepo = pkgSplitVer[0]

  if name == "":
    name = pkg
    repo = findPkgRepo(pkg)

  if nameWithRepo == "":
    nameWithRepo = name

  debug "parsePkgInfo ran, name: '"&name&"', repo: '"&repo&"', version: '"&version&"', commit: '"&commit&"', nameWithRepo: '"&nameWithRepo&"'"
  return (name: name, repo: repo, version: version, commit: commit,
          nameWithRepo: nameWithRepo)


proc appenderInternal(r: string, a: string, b: string, c = "",
        removeInt = 0): string =
  # Appends spaces so it looks nicer.
  var final = r

  for i in 1 .. 40 - (a.len + b.len + c.len - removeInt):
    final = final&" "

  return final


proc printPackagesPrompt*(packages: string, yes: bool, no: bool,
        isInstallDir = @[""], dependents = @[""], binary = false) =
  ## Prints the packages summary prompt.
  var finalPkgs: string
  var pkgLen: int

  if parseBool(getConfigValue("Options", "verticalSummary", "false")):
    pkgLen = packages.split(" ").len
    echo "Packages ("&($pkgLen)&")                             New Version\n"
    for i in packages.split(" "):
      var pkgRepo: string
      var pkg = i
      var pkgFancy: string
      var pkgVer: string

      if i in isInstallDir:
        pkgRepo = absolutePath(pkg).parentDir()
        pkg = lastPathPart(pkg)
      else:
        let pkgSplit = parsePkgInfo(i)
        pkgRepo = pkgSplit.repo
        pkg = pkgSplit.name
        pkgFancy = pkgSplit.nameWithRepo
        pkgVer = pkgSplit.version

      let upstreamRunf = parseRunfile(pkgRepo&"/"&pkg)

      if isEmptyOrWhitespace(pkgVer):
        pkgVer = upstreamRunf.versionString

      var r = lastPathPart(pkgRepo)&"/"&pkg
      if packageExists(pkg, "/"):
        let localPkg = getPackage(pkg, "/")
        if localPkg.version != pkgVer:
          r = r&"-"&localPkg.version
          r = appenderInternal(r, pkgFancy, lastPathPart(pkgRepo),
                  localPkg.version)
          r = r&pkgVer
        else:
          r = r&"-"&localPkg.version
          r = appenderInternal(r, pkgFancy, lastPathPart(pkgRepo),
                  localPkg.version)
          if i in dependents:
            if binary:
              r = r&"reinstall"
            else:
              r = r&"rebuild"
          else:
            r = r&"up-to-date"
      else:
        r = appenderInternal(r, pkgFancy, "", lastPathPart(pkgRepo), 1)
        r = r&upstreamRunf.versionString

      echo r

  else:
    for i in packages.split(" "):
      inc(pkgLen)
      var upstreamRunf: runFile

      var pkgRepo: string
      var pkgVer: string
      var pkgFancy: string
      var pkg = i

      if i in isInstallDir:
        pkgRepo = absolutePath(pkg).parentDir()
        pkg = lastPathPart(pkg)
      else:
        var pkgSplit = parsePkgInfo(i)
        pkgRepo = pkgSplit.repo
        pkg = pkgSplit.name
        pkgFancy = pkgSplit.nameWithRepo
        pkgVer = pkgSplit.version

      if packageExists(pkg, "/") and pkgRepo != "":
        upstreamRunf = parseRunfile(pkgRepo&"/"&pkg)

        if isEmptyOrWhitespace(pkgVer):
          pkgVer = upstreamRunf.versionString

        if getPackage(pkg, "/").version != pkgVer:
          finalPkgs = appendInternal(pkgFancy&" -> ".green&pkgVer, finalPkgs)
          continue
        elif pkg in dependents:
          if binary:
            finalPkgs = appendInternal(
                    pkgFancy&" -> ".blue&"reinstall", finalPkgs)
          else:
            finalPkgs = appendInternal(
                    pkgFancy&" -> ".blue&"rebuild", finalPkgs)

          continue


      finalPkgs = appendInternal(pkgFancy, finalPkgs)

    echo "Packages ("&($pkgLen)&"): "&finalPkgs

  var output: string

  if yes:
    output = "y"
  elif no:
    output = "n"
  else:
    stdout.write "Do you want to continue? (y/N) "
    output = readLine(stdin)

  if output.toLower() != "y":
    info("exiting")
    quit(0)

proc ctrlc*() {.noconv.} =
  for path in walkFiles("/var/cache/kpkg/archives/arch/"&hostCPU&"/*.partial"):
    removeFile(path)

  echo ""
  info "ctrl+c pressed, shutting down"
  quit(130)

proc printReplacesPrompt*(pkgs: seq[string], root: string, isDeps = false,
        isInstallDir = false) =
  ## Prints a replacesPrompt.
  for i in pkgs:
    var pkg = i
    var pkgRepo: string

    if isInstallDir:
      pkgRepo = absolutePath(pkg).parentDir()
      pkg = lastPathPart(pkg)
    else:
      let pkgSplit = parsePkgInfo(i)
      pkg = pkgSplit.name
      pkgRepo = pkgSplit.repo

    for p in parseRunfile(pkgRepo&"/"&pkg).replaces:
      if isDeps and packageExists(p, root):
        continue
      if packageExists(p, root) and not isReplaced(p, root).replaced:
        info "'"&i&"' replaces '"&p&"'"

