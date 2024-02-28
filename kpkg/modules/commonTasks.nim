import os
import posix
import config
import logger
import strutils
import sequtils
import parsecfg
import runparser
import posix_utils

proc isEmptyDir(dir: string): bool = 
    return toSeq(walkdir dir).len == 0

proc copyFileWithPermissionsAndOwnership*(source, dest: string, options = {cfSymlinkAsIs}) =
    ## Copies a file with both permissions and ownership.
    
    if dirExists(source) and not symlinkExists(source):
        debug "\""&source&"\" is a dir (and not a symlink), just going to ignore"
        debug "this shouldn't happen"
        return
    
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

proc createDirWithPermissionsAndOwnership*(source, dest: string, followSymlinks = true) =
    
    if fileExists(dest):
        debug "\""&dest&"\" is a file, returning early"
        return
    
    if isEmptyDir(dest):
        debug "\""&dest&"\" is empty, just going to overwrite"
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
    err("couldn't load "&root&"/etc/kreato-release")

proc packageInstalled*(package, root: string): bool =
  # Checks if an package is installed.
  if dirExists("/var/cache/kpkg/installed/"&package):
    return true
  else:
    return false

proc getLibc*(root: string): string =
  ## Returns the libc.
  try:
    return loadConfig(root&"/etc/kreato-release").getSectionValue("Core", "libc")
  except CatchableError:
    err("couldn't load "&root&"/etc/kreato-release")

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

  return system&"-"&conf.getSectionValue("Core", "init")&"-"&conf.getSectionValue("Core", "tlsLibrary")

proc green*(s: string): string = "\e[32m" & s & "\e[0m" 

proc appendInternal(f: string, t: string): string =
  # convenience proc to append.
  if isEmptyOrWhitespace(t):
    return f
  else:
    return t&" "&f

proc appenderInternal(r: string, a: string, b: string, c = "", removeInt = 0): string =
  # Appends spaces so it looks nicer.
  var final = r
  
  for i in 1 .. 40 - (a.len + b.len + c.len - removeInt):
    final = final&" "
  
  return final


proc printPackagesPrompt*(packages: string, yes: bool, no: bool, isInstallDir = @[""]) =
  ## Prints the packages summary prompt.
  var finalPkgs: string
  var pkgLen: int
  
  if parseBool(getConfigValue("Options", "verticalSummary", "false")):
      pkgLen = packages.split(" ").len
      echo "Packages ("&($pkgLen)&")                             New Version\n"
      for i in packages.split(" "):
        var pkgRepo: string
        var pkg = i
        
        if i in isInstallDir:
          pkgRepo = absolutePath(pkg).parentDir()
          pkg = lastPathPart(pkg)
        else:        
          let pkgSplit = i.split("/")
          if pkgSplit.len > 1:
            pkgRepo = "/etc/kpkg/repos/"&pkgSplit[0]
            pkg = pkgSplit[1]
          else:
            pkgRepo = findPkgRepo(i)

        let upstreamRunf = parseRunfile(pkgRepo&"/"&pkg)
        var r = lastPathPart(pkgRepo)&"/"&pkg
        if fileExists("/var/cache/kpkg/installed/"&pkg&"/run"):
          let localRunf = parseRunfile("/var/cache/kpkg/installed/"&pkg)
          if localRunf.versionString != upstreamRunf.versionString:
            r = r&"-"&localRunf.versionString
            r = appenderInternal(r, pkg, lastPathPart(pkgRepo), localRunf.versionString)
            r = r&upstreamRunf.versionString
          else:
            r = r&"-"&localRunf.versionString
            r = appenderInternal(r, pkg, lastPathPart(pkgRepo), localRunf.versionString)
            r = r&"up-to-date"
        else:
            r = appenderInternal(r, pkg, "", lastPathPart(pkgRepo), 1)
            r = r&upstreamRunf.versionString
      
        echo r
      
  else:
    for i in packages.split(" "):
      inc(pkgLen)
      var upstreamRunf: runFile
      
      var pkgRepo: string
      var pkg = i
      let pkgSplit = i.split("/")
      
      if i in isInstallDir:
        pkgRepo = absolutePath(pkg).parentDir()
        pkg = lastPathPart(pkg)
      else:
        if pkgSplit.len > 1:
          pkgRepo = "/etc/kpkg/repos/"&pkgSplit[0]
          pkg = pkgSplit[1]
        else:
          pkgRepo = findPkgRepo(i)

      if fileExists("/var/cache/kpkg/installed/"&pkg&"/run") and pkgRepo != "":
        upstreamRunf = parseRunfile(pkgRepo&"/"&pkg)
        if parseRunfile("/var/cache/kpkg/installed/"&pkg).versionString != upstreamRunf.versionString:
          finalPkgs = appendInternal(i&" -> ".green&upstreamRunf.versionString, finalPkgs)
          continue

      finalPkgs = appendInternal(i, finalPkgs)
  
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
    info("exiting", true)

proc ctrlc*() {.noconv.} =
  for path in walkFiles("/var/cache/kpkg/archives/arch/"&hostCPU&"/*.partial"):
    removeFile(path)

  echo ""
  info "ctrl+c pressed, shutting down"
  quit(130)

proc printReplacesPrompt*(pkgs: seq[string], root: string, isDeps = false, isInstallDir = false) =
  ## Prints a replacesPrompt.
  for i in pkgs:
    var pkg = i
    let pkgSplit = i.split("/")
    var pkgRepo: string

    if isInstallDir:
      pkgRepo = absolutePath(pkg).parentDir()
      pkg = lastPathPart(pkg)
    else:
      if pkgSplit.len > 1:
        pkgRepo = "/etc/kpkg/repos/"&pkgSplit[0]
        pkg = pkgSplit[1]
      else:
        pkgRepo = findPkgRepo(i)

    for p in parseRunfile(pkgRepo&"/"&pkg).replaces:
      if isDeps and dirExists(root&"/var/cache/kpkg/installed/"&p):
        continue
      if dirExists(root&"/var/cache/kpkg/installed/"&p) and not symlinkExists(
          root&"/var/cache/installed/"&p):
        info "'"&i&"' replaces '"&p&"'"

