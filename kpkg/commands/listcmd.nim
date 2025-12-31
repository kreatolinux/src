import os
import strutils
import providescmd
import ../modules/config
import ../modules/sqlite

proc getListPackagesRepo(root = "/", ignoreList = @[""]): seq[string] =
  var res: seq[string]

  for i in getConfigValue("Repositories", "repoDirs").split(" "):
    for p in walkDirs(i&"/*"):
      if lastPathPart(p) in ignoreList:
        continue
      else:
        res = res&lastPathPart(p)

  return res


proc list*(installed = false, color = true) =
  ## List packages.
  var packageList = getListPackages("/")

  if not installed:
    packageList = getListPackagesRepo("/", packageList)

  for package in packageList:
    echo printProvides("", package, color, false)
