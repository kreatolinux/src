import os
import logger
import strutils
import sequtils
import runparser
import dephandler
import commonTasks

proc dependencyCheck(package: string, installedDir: string, root: string, force: bool) =
  ## Checks if a package is a dependency on another package.
  setCurrentDir(installedDir)
  for i in toSeq(walkDirs("*")):
    let d = dephandler(@[i], root = root)
    for a in d:
      if a == package:
        if force:
          warn(i&" is dependent on "&package&", removing anyway")
        else:
          err(i&" is dependent on "&package, false)

proc removeInternal*(package: string, root = "",
        installedDir = root&"/var/cache/kpkg/installed",
        ignoreReplaces = false, force = true, depCheck = false,
            noRunfile = false) =

  let init = getInit(root)

  if dirExists(installedDir&"/"&package&"-"&init):
    removeInternal(package&"-"&init, root, installedDir, ignoreReplaces)

  var actualPackage: string

  if symlinkExists(installedDir&"/"&package):
    actualPackage = expandSymlink(installedDir&"/"&package)
  else:
    actualPackage = package

  if not dirExists(installedDir&"/"&actualPackage):
    err("package "&package&" is not installed", false)

  var pkg: runFile

  if not noRunfile:
    pkg = parseRunfile(installedDir&"/"&actualPackage)

    if depCheck:
      dependencyCheck(package, installedDir, root, force)

    if not pkg.isGroup:
      if not fileExists(installedDir&"/"&actualPackage&"/list_files"):
        warn "Package doesn't have a file list. Possibly broken package? Removing anyway."
        removeDir(installedDir&"/"&package)
        return

  for line in lines installedDir&"/"&actualPackage&"/list_files":
    discard tryRemoveFile(root&"/"&line)
    if isEmptyOrWhitespace(toSeq(walkDirRec(root&"/"&line)).join("")):
      removeDir(root&"/"&line)

  if not ignoreReplaces and not noRunfile:
    for i in pkg.replaces:
      if symlinkExists(installedDir&"/"&i):
        removeFile(installedDir&"/"&i)

  removeDir(installedDir&"/"&package)
