import std/[os, osproc, strutils]
import ../sqlite
import ../../../common/logging

proc parseNeededSonames*(readelfOutput: string): seq[string] =
  for line in readelfOutput.splitLines:
    if "(NEEDED)" notin line:
      continue
    let start = line.find("[")
    let finish = line.find("]", start + 1)
    if start >= 0 and finish > start:
      result.add(line[start + 1 ..< finish])

proc shouldScanElfFile(filePath: string): bool =
  let name = filePath.split('/')[^1]
  return filePath.startsWith("bin/") or
      filePath.startsWith("sbin/") or
      filePath.startsWith("usr/bin/") or
      filePath.startsWith("usr/sbin/") or
      filePath.startsWith("usr/libexec/") or
      ((filePath.startsWith("lib/") or filePath.startsWith("usr/lib/")) and
      ".so" in name)

proc orderSonameConsumers*(consumers: seq[string],
                          depResolver: proc(pkg: string): seq[string]): seq[string] =
  var visiting: seq[string]
  var visited: seq[string]
  var ordered: seq[string]

  proc visit(pkg: string) =
    if pkg in visited:
      return
    if pkg in visiting:
      debug "orderSonameConsumers: dependency cycle at " & pkg
      return

    visiting.add(pkg)
    for dep in depResolver(pkg):
      if dep in consumers:
        visit(dep)
    discard visiting.pop()

    if pkg notin visited:
      visited.add(pkg)
      ordered.add(pkg)

  for consumer in consumers:
    visit(consumer)

  return ordered

proc getNeededSonames*(filePath: string): seq[string] =
  let (output, exitCode) = execCmdEx("readelf -d " & quoteShell(filePath) &
      " 2>/dev/null")
  if exitCode != 0:
    return @[]
  return parseNeededSonames(output)

proc getInstalledSonames*(package: string, root: string): seq[string] =
  debug "getInstalledSonames: checking package '" & package & "' at root '" &
      root & "'"
  for filePath in getListFiles(package, root):
    let name = filePath.split('/')[^1]
    if name.startsWith("lib") and ".so." in name:
      debug "getInstalledSonames: found " & name
      result.add(name)
  debug "getInstalledSonames: found " & $result.len & " sonames"

proc getElfRuntimeDependents*(packages: seq[string], root: string): seq[string] =
  var changedSonames: seq[string]
  for package in packages:
    if not packageExists(package, root):
      continue
    for soname in getInstalledSonames(package, root):
      if soname notin changedSonames:
        changedSonames.add(soname)

  if changedSonames.len == 0:
    debug "getElfRuntimeDependents: no installed sonames found"
    return @[]

  debug "getElfRuntimeDependents: scanning for NEEDED entries: " &
      changedSonames.join(", ")
  for package in getListPackages(root):
    if package in packages:
      continue
    for filePath in getListFiles(package, root):
      if not shouldScanElfFile(filePath):
        continue
      let absolutePath = root / filePath
      if not fileExists(absolutePath) and not symlinkExists(absolutePath):
        continue
      for needed in getNeededSonames(absolutePath):
        if needed in changedSonames:
          debug "getElfRuntimeDependents: " & package & " needs " & needed &
              " via " & filePath
          if package notin result:
            result.add(package)
          break
      if package in result:
        break

  debug "getElfRuntimeDependents: found " & $result.len & " dependents"

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
