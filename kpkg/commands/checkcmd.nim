import os
import strutils
import ../modules/sqlite
import ../../common/logging
import ../modules/checksums

proc reportCheckError(msg: string) =
  ## Report a check error - debug if debug mode, fatal otherwise.
  debug msg
  if not isEnabled(lvlDebug):
    fatal msg

proc checkInternal(package: Package, root: string, lines = getFilesPackage(
        package, root), checkEtc: bool) =
  for line in lines:

    let actPath = line.path.replace("\"", "")
    let fullPath = root&"/"&actPath

    if dirExists(fullPath):
      continue

    if actPath.parentDir().lastPathPart == "etc" and (not checkEtc):
      continue

    if not fileExists(fullPath):
      reportCheckError("'" & fullPath.relativePath(root) &
          "' doesn't exist, please reinstall '" & package.name & "'")
      continue

    if line.blake2Checksum == "":
      #debug "'"&line&"' doesn't have checksum, skipping"
      continue

    let sum = line.blake2Checksum
    let actualSum = getSum(fullPath, "b2")

    #debug "checking '"&fullPath.relativePath(root)&"' with checksum '"&sum&"' and actual checksum '"&actualSum&"'"

    if actualSum != sum:
      reportCheckError("'" & fullPath.relativePath(root) &
          "' has an invalid checksum, please reinstall '" & package.name & "'")

proc check*(package = "", root = "/", silent = false, checkEtc = false) =
  ## Check packages in filesystem for errors.
  if not silent:
    info "the check may take a while, please wait"
  setCurrentDir(root)

  if isEmptyOrWhitespace(package):
    for pkg in getListPackagesType(root):
      debug "checking package '"&pkg.name&"'"
      checkInternal(pkg, root, getFilesPackage(pkg, root), checkEtc)
  else:
    if not packageExists(package, root):
      error("package '"&package&"' doesn't exist")
      quit(1)
    else:
      let pkg = getPackage(package, root)
      checkInternal(pkg, root, getFilesPackage(pkg, root), checkEtc)

  if not silent:
    info("done")

