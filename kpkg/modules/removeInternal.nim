import os
import osproc
import logger
import strutils
import sequtils
import runparser
import dephandler
import commonTasks

proc dependencyCheck(package: string, installedDir: string, root: string, force: bool, noWarnErr = false, ignorePackage:seq[string]): bool =
  ## Checks if a package is a dependency on another package.
  setCurrentDir(installedDir)
  for i in toSeq(walkDirs("*")):
    let d = parseRunfile(installedDir&"/"&i).deps
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

proc bloatDepends*(package: string, installedDir: string, root: string): seq[string] =
  ## Returns unused dependent packages, if they are available.
  setCurrentDir(installedDir)
  let depends = dephandler(@[package], root = root, forceInstallAll = true, chkInstalledDirInstead = true)
  var returnStr: seq[string]

  for dep in depends:
    debug "bloatDepends: checking "&dep
    if dependencyCheck(dep, installedDir, root, false, true, ignorePackage = @[package]) and not fileExists(installedDir&"/"&dep&"/manualInstall"):
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

  if not dirExists(installedDir&"/"&actualPackage):
    err("package "&package&" is not installed")

  var pkg: runFile

  if not noRunfile:
    debug "remove: parsing runFile"
    pkg = parseRunfile(installedDir&"/"&actualPackage)

    if depCheck:
      debug "Dependency check starting"
      debug package&" "&installedDir&" "&root
      discard dependencyCheck(package, installedDir, root, force, ignorePackage = fullPkgList)
      
    if not pkg.isGroup:
      debug "Starting removal process"
      if not fileExists(installedDir&"/"&actualPackage&"/list_files"):
        warn "Package doesn't have a file list. Possibly broken package? Removing anyway."
        removeDir(installedDir&"/"&package)
        return

  for actualLine in lines installedDir&"/"&actualPackage&"/list_files":
    let line = actualLine.split("=")[0]
    if not removeConfigs and not noRunfile:
      if not (line in pkg.backup):
        discard tryRemoveFile(root&"/"&line)
    else:
      discard tryRemoveFile(root&"/"&line)
  debug "files removed"

  # Double check so every empty dir gets removed
  for actualLine in lines installedDir&"/"&actualPackage&"/list_files":
    let line = actualLine.split("=")[0]
    if isEmptyOrWhitespace(toSeq(walkDir(root&"/"&line)).join("")) and dirExists(root&"/"&line):
      removeDir(root&"/"&line)
  debug "dirs removed"

  if not ignoreReplaces and not noRunfile:
    for i in pkg.replaces:
      if symlinkExists(installedDir&"/"&i):
        removeFile(installedDir&"/"&i)

  if runPostRemove:
    if execCmdEx(". "&installedDir&"/"&actualPackage&"/run && command -v postremove > /dev/null").exitCode == 0:
      if execCmdEx(". "&installedDir&"/"&actualPackage&"/run && postremove").exitCode != 0:
        err "postremove failed"

  removeDir(installedDir&"/"&package)
