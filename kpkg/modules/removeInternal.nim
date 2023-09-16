import os
import logger
import strutils
import sequtils
import runparser
import dephandler
import commonTasks

proc dependencyCheck(package: string, installedDir: string, root: string) =
  ## Checks if a package is a dependency on another package.
  let d = dephandler(toSeq(walkDirs(installedDir&"/*")), root = root)
  for i in d:
    if i == package:
      err(i&" is dependent on "&package)

proc removeInternal*(package: string, root = "",
        installedDir = root&"/var/cache/kpkg/installed",
        ignoreReplaces = false) =

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

  let pkg = parse_runfile(installedDir&"/"&actualPackage)

  dependencyCheck(package, installedDir, root)

  if not pkg.isGroup:
    if not fileExists(installedDir&"/"&actualPackage&"/list_files"):
      warn "Package doesn't have a file list. Possibly broken package? Removing anyway."
      removeDir(installedDir&"/"&package)
      return

    for line in lines installedDir&"/"&actualPackage&"/list_files":
      discard tryRemoveFile(root&"/"&line)

      if isEmptyOrWhitespace(toSeq(walkDirRec(root&"/"&line)).join("")):
        removeDir(root&"/"&line)

  if not ignoreReplaces:
    for i in pkg.replaces:
      if symlinkExists(installedDir&"/"&i):
        removeFile(installedDir&"/"&i)

  removeDir(installedDir&"/"&package)
