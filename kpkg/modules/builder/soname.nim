import std/[os, strutils]
import ../sqlite
import ../../../common/logging

proc getInstalledSonames*(package: string, root: string): seq[string] =
  debug "getInstalledSonames: checking package '" & package & "' at root '" &
      root & "'"
  for filePath in getListFiles(package, root):
    let name = filePath.split('/')[^1]
    if name.startsWith("lib") and ".so." in name:
      debug "getInstalledSonames: found " & name
      result.add(name)
  debug "getInstalledSonames: found " & $result.len & " sonames"

proc getBuildSonames*(buildRoot: string): seq[string] =
  debug "getBuildSonames: scanning " & buildRoot
  for file in walkDirRec(buildRoot):
    let name = file.split('/')[^1]
    if name.startsWith("lib") and ".so." in name:
      debug "getBuildSonames: found " & name
      result.add(name)
  debug "getBuildSonames: found " & $result.len & " sonames"

proc hasSonameChanged*(buildRoot: string, package: string, root: string): bool =
  debug "hasSonameChanged: buildRoot=" & buildRoot & " package=" & package &
      " root=" & root
  let newSonames = getBuildSonames(buildRoot)
  if newSonames.len == 0:
    debug "hasSonameChanged: no new sonames found, returning false"
    return false
  debug "hasSonameChanged: packageExists(" & package & ", " & root & ")"
  if not packageExists(package, root):
    debug "hasSonameChanged: package not installed, returning false"
    return false
  let oldSonames = getInstalledSonames(package, root)
  debug "hasSonameChanged: old=" & oldSonames.join(", ") & " new=" &
      newSonames.join(", ")
  if oldSonames.len != newSonames.len:
    debug "hasSonameChanged: soname count differs, returning true"
    return true
  for s in newSonames:
    if s notin oldSonames:
      debug "hasSonameChanged: new soname '" & s & "' not in old set, returning true"
      return true
  debug "hasSonameChanged: no soname changes detected, returning false"
  return false
