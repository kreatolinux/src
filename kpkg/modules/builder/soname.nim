import std/[os, strutils]
import ../sqlite

proc getInstalledSonames*(package: string, root: string): seq[string] =
  for filePath in getListFiles(package, root):
    let name = filePath.split('/')[^1]
    if name.startsWith("lib") and ".so." in name:
      result.add(name)

proc getBuildSonames*(buildRoot: string): seq[string] =
  for file in walkDirRec(buildRoot):
    let name = file.split('/')[^1]
    if name.startsWith("lib") and ".so." in name:
      result.add(name)

proc hasSonameChanged*(buildRoot: string, package: string, root: string): bool =
  let newSonames = getBuildSonames(buildRoot)
  if newSonames.len == 0:
    return false
  if not packageExists(package, root):
    return false
  let oldSonames = getInstalledSonames(package, root)
  if oldSonames.len != newSonames.len:
    return true
  for s in newSonames:
    if s notin oldSonames:
      return true
  return false
