import os
import config
import logger
import strutils
import parsecfg
import runparser

const lockfile = "/tmp/kpkg.lock"

proc getInit*(root: string): string =
  ## Returns the init system.
  try:
    return loadConfig(root&"/etc/kreato-release").getSectionValue("Core", "init")
  except CatchableError:
    err("couldn't load "&root&"/etc/kreato-release")

proc createLockfile*() =
  writeFile(lockfile, "")

proc checkLockfile*() =
  if fileExists(lockfile):
    err("lockfile exists, will not proceed", false)

proc removeLockfile*() =
  removeFile(lockfile)

proc printPackagesPrompt*(packages: string, yes: bool, no: bool) =
  ## Prints the packages summary prompt.

  echo "Packages: "&packages

  var output: string

  if yes:
    output = "y"
  elif no:
    output = "n"
  else:
    stdout.write "Do you want to continue? (y/N) "
    output = readLine(stdin)

  if output.toLower() != "y":
    info("exiting", true)

proc ctrlc*() {.noconv.} =
  for path in walkFiles("/var/cache/kpkg/archives/arch/"&hostCPU&"/*.partial"):
    removeFile(path)

  echo ""
  info "ctrl+c pressed, shutting down"
  quit(130)

proc printReplacesPrompt*(pkgs: seq[string], root: string, isDeps = false) =
  ## Prints a replacesPrompt.
  for i in pkgs:
    for p in parseRunfile(findPkgRepo(i)&"/"&i).replaces:
      if isDeps and dirExists(root&"/var/cache/kpkg/installed/"&p):
        continue
      if dirExists(root&"/var/cache/kpkg/installed/"&p) and not symlinkExists(
          root&"/var/cache/installed/"&p):
        info "'"&i&"' replaces '"&p&"'"

