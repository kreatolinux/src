import os
import osproc
import sqlite
import logger
import strutils
import sequtils
import dephandler
import commonTasks

proc dependencyCheck(package: string, root: string, force: bool, noWarnErr = false, ignorePackage:seq[string]): bool =
  ## Checks if a package is a dependency on another package.
  for i in getListPackages(root):
    let d = getPackage(i, root).deps.split("!!k!!")
    for a in d:
      if a == package and not (i in ignorePackage):
        if not noWarnErr:
          if force:
            warn(i&" is dependent on "&package&", removing anyway")
          else:
            err(i&" is dependent on "&package, true)
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
  let depends = dephandler(@[package], root = root, forceInstallAll = true, chkInstalledDirInstead = true)
  var returnStr: seq[string]

  for dep in depends:
    debug "bloatDepends: checking "&dep
    if dependencyCheck(dep, root, false, true, ignorePackage = @[package]) and not getPackage(package, root).manualInstall:
      debug "bloatDepends: adding "&dep
      returnStr = returnStr&dep
  return returnStr

proc removeInternal*(package: string, root = "",
        installedDir = root&"/var/cache/kpkg/installed",
        ignoreReplaces = false, force = true, depCheck = false,
            noRunfile = false, fullPkgList = @[""], removeConfigs = false, runPostRemove = false, initCheck = true) =
  
  if initCheck: 
    let init = getInit(root)

    if dirExists(installedDir&"/"&package&"-"&init):
      removeInternal(package&"-"&init, root, installedDir, ignoreReplaces, force, depCheck, noRunfile, fullPkgList, removeConfigs, runPostRemove)

  var actualPackage: string

  if symlinkExists(installedDir&"/"&package):
    actualPackage = expandSymlink(installedDir&"/"&package)
  else:
    actualPackage = package

  if not packageExists(actualPackage, root):
    err("package "&package&" is not installed")

  var pkg = getPackage(actualPackage, root)

  if not noRunfile:

    if depCheck:
      debug "Dependency check starting"
      debug package&" "&installedDir&" "&root
      discard dependencyCheck(package, root, force, ignorePackage = fullPkgList)
      
    if not pkg.isGroup:
      debug "Starting removal process"
 
  let listFiles = getListFiles(actualPackage, root)
    
  for line in listFiles:
    if not removeConfigs and not noRunfile:
      if not (line in pkg.backup.split("!!k!!")):
        discard tryRemoveFileCustom(root&"/"&line)
    else:
      discard tryRemoveFileCustom(root&"/"&line)
  debug "files removed"

  # Double check so every empty dir gets removed
  for line in listFiles:
    if isEmptyOrWhitespace(toSeq(walkDir(root&"/"&line)).join("")) and dirExists(root&"/"&line):
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
    if execCmdEx(". "&installedDir&"/"&actualPackage&"/run && command -v postremove > /dev/null").exitCode == 0:
      if execCmdEx(". "&installedDir&"/"&actualPackage&"/run && postremove").exitCode != 0:
        err "postremove failed"

  removeDir(installedDir&"/"&package)
