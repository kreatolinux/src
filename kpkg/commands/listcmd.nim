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


proc list*(installed = false, color = true, showExcluded = false) =
  var packageList = getListPackages("/")

  if not installed:
    packageList = getListPackagesRepo("/", packageList)

  for package in packageList:
    let repo = findPkgRepo(package)
    let repoName = if not isEmptyOrWhitespace(repo): lastPathPart(
        repo) else: "local"
    let excluded = isExcluded(package, repoName)
    if excluded and not showExcluded:
      continue
    echo printProvides("", package, color, false)
