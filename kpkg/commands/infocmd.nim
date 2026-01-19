import os
import strutils
import ../modules/sqlite
import ../../common/logging
import ../modules/config
import ../modules/runparser

proc info*(package: seq[string], testing = false): string =
  ## Get information about packages.

  if package.len == 0:
    error("Please enter a package name")
    quit(1)

  let repo = findPkgRepo(package[0])

  if not dirExists(repo&"/"&package[0]):
    error("Package "&package[0]&" doesn't exist")
    quit(1)

  var pkg: runFile
  try:
    pkg = parseRunfile(repo&"/"&package[0])
  except CatchableError:
    raise

  echo "package name: "&pkg.pkg
  echo "package version: "&pkg.version
  echo "package release: "&pkg.release
  if pkg.license.len > 0:
    echo "license: "&pkg.license.join(" ")
  when declared(pkg.epoch):
    echo "package epoch: "&pkg.epoch
  if packageExists(package[0]):
    return "installed: yes"

  # don't error when package isn't installed during testing
  const ret = "installed: no"
  if testing:
    return ret

  # return err if package isn't installed (for scripting :p)
  error(ret)
  quit(1)
