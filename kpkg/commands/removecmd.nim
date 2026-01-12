import os
import parsecfg
import strutils
import ../modules/sqlite
import ../modules/logger
import ../modules/lockfile
import ../modules/processes
import ../modules/removeInternal

proc remove*(packages: seq[string], yes = false, root = "",
        force = false, autoRemove = false, configRemove = false,
                ignoreBasePackages = false): string =
  ## Remove packages.

  # bail early if user isn't admin
  if not isAdmin():
    error("you have to be root for this action.")
    quit(1)

  isKpkgRunning()
  checkLockfile()

  if packages.len == 0:
    error("please enter a package name")
    quit(1)

  var output: string
  var packagesFinal = packages

  if autoRemove:
    for package in packages:
      if not packageExists(package, root):
        error("package "&package&" is not installed")
        quit(1)
      packagesFinal = bloatDepends(package, root)&packagesFinal

  if not ignoreBasePackages:
    for package in packagesFinal:
      let basePackage = getPackage(package, root).basePackage
      if basePackage:
        error("\""&package&"\" is a part of base system, cannot remove")
        quit(1)

  if not yes:
    echo "Removing: "&packagesFinal.join(" ")
    stdout.write "Do you want to continue? (y/N) "
    output = readLine(stdin)
  else:
    output = "y"

  if output.toLower() == "y":
    createLockfile()
    for i in packagesFinal:
      removeInternal(i, root, force = force, depCheck = true,
              fullPkgList = packages, removeConfigs = configRemove,
              runPostRemove = true)
      info("package "&i&" removed")
    removeLockfile()
    info("done")
    quit(0)

  info("exiting")
  quit(0)
