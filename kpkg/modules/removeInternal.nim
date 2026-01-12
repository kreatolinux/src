import os
import sqlite
import logger
import strutils
import sequtils
import dephandler
import commonTasks
import runparser
import run3/executor
import run3/run3

proc dependencyCheck(package: string, root: string, force: bool,
    noWarnErr = false, ignorePackage: seq[string]): bool =
  ## Checks if a package is a dependency on another package.
  for i in getListPackages(root):
    let d = getPackage(i, root).deps.split("!!k!!")
    for a in d:
      if a == package and not (i in ignorePackage):
        if not noWarnErr:
          if force:
            warn(i&" is dependent on "&package&", removing anyway")
          else:
            fatal(i&" is dependent on "&package)
        else:
          return false
  return true

proc tryRemoveFileCustom(file: string): bool =
  # tryRemoveFile wrapper
  # that checks if the file is a
  # dir or not.
  if dirExists(file):
    return # We remove dirs on the second check
  return tryRemoveFile(file)


proc bloatDepends*(package: string, root: string): seq[string] =
  ## Returns unused dependent packages, if they are available.
  let depends = dephandler(@[package], root = root, forceInstallAll = true,
      chkInstalledDirInstead = true)
  var returnStr: seq[string]

  for dep in depends:
    debug "bloatDepends: checking "&dep
    if dependencyCheck(dep, root, false, true, ignorePackage = @[package]) and
        not getPackage(package, root).manualInstall:
      debug "bloatDepends: adding "&dep
      returnStr = returnStr&dep
  return returnStr

proc removeInternal*(package: string, root = "",
        installedDir = root&"/var/cache/kpkg/installed",
        ignoreReplaces = false, force = true, depCheck = false,
            noRunfile = false, fullPkgList = @[""], removeConfigs = false,
                runPostRemove = false, initCheck = true) =

  if initCheck:
    let init = getInit(root)

    if dirExists(installedDir&"/"&package&"-"&init):
      removeInternal(package&"-"&init, root, installedDir, ignoreReplaces,
          force, depCheck, noRunfile, fullPkgList, removeConfigs, runPostRemove)

  var actualPackage: string

  if symlinkExists(installedDir&"/"&package):
    actualPackage = expandSymlink(installedDir&"/"&package)
  else:
    actualPackage = package

  if not packageExists(actualPackage, root):
    fatal("package "&package&" is not installed")

  var pkg = getPackage(actualPackage, root)
  debug "removeInternal: getPackage completed for '"&actualPackage&"'"

  if not noRunfile:
    debug "removeInternal: noRunfile is false, entering block"

    if depCheck:
      debug "Dependency check starting"
      debug package&" "&installedDir&" "&root
      discard dependencyCheck(package, root, force, ignorePackage = fullPkgList)

    debug "removeInternal: pkg.isGroup = " & $pkg.isGroup
    if not pkg.isGroup:
      debug "Starting removal process"

  debug "removeInternal: about to call getListFiles"
  let listFiles = getListFiles(actualPackage, root)
  debug "removeInternal: getListFiles returned " & $listFiles.len & " files"

  for line in listFiles:
    if not removeConfigs and not noRunfile:
      if not (line in pkg.backup.split("!!k!!")):
        discard tryRemoveFileCustom(root&"/"&line)
    else:
      discard tryRemoveFileCustom(root&"/"&line)
  debug "files removed"

  # Double check so every empty dir gets removed
  for line in listFiles:
    if isEmptyOrWhitespace(toSeq(walkDir(root&"/"&line)).join("")) and
        dirExists(root&"/"&line):
      if symlinkExists(root&"/"&line):
        removeFile(root&"/"&line)
      else:
        removeDir(root&"/"&line)
  debug "dirs removed"

  if not ignoreReplaces and not noRunfile:
    for i in pkg.replaces.split("!!k!!"):
      if symlinkExists(installedDir&"/"&i):
        removeFile(installedDir&"/"&i)

  rmPackage(actualPackage, root)

  if runPostRemove:
    var run3Path = installedDir&"/"&actualPackage&"/run3"

    if not fileExists(run3Path) and fileExists(
        installedDir&"/"&actualPackage&"/run"):
      run3Path = installedDir&"/"&actualPackage&"/run"

    if fileExists(run3Path):
      try:
        # We use parseRunfile to get the parsed Run3 object
        let parsedPkg = runparser.parseRunfile(installedDir&"/"&actualPackage)

        # Init context
        let ctx = initFromRunfile(parsedPkg.run3Data.parsed, destDir = root,
            srcDir = installedDir&"/"&actualPackage, buildRoot = root)
        ctx.builtinEnv("ROOT", root)
        ctx.builtinEnv("DESTDIR", root)
        ctx.passthrough = true

        var postremoveFunc = ""
        if parsedPkg.run3Data.parsed.hasFunction("postremove_"&replace(
            actualPackage, '-', '_')):
          postremoveFunc = "postremove_"&replace(actualPackage, '-', '_')
        elif parsedPkg.run3Data.parsed.hasFunction("postremove"):
          postremoveFunc = "postremove"

        if postremoveFunc != "":
          if executeRun3Function(ctx, parsedPkg.run3Data.parsed,
              postremoveFunc) != 0:
            fatal "postremove failed"
      except:
        warn "Failed to execute Run3 postremove: " & getCurrentExceptionMsg()

  removeDir(installedDir&"/"&package)
