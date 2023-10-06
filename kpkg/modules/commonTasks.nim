import os
import config
import logger
import strutils
import parsecfg
import runparser

proc getInit*(root: string): string =
  ## Returns the init system.
  try:
    return loadConfig(root&"/etc/kreato-release").getSectionValue("Core", "init")
  except CatchableError:
    err("couldn't load "&root&"/etc/kreato-release")

proc green*(s: string): string = "\e[32m" & s & "\e[0m" 

proc appendInternal(f: string, t: string): string =
  # convenience proc to append.
  if isEmptyOrWhitespace(t):
    return f
  else:
    return t&" "&f

proc printPackagesPrompt*(packages: string, yes: bool, no: bool) =
  ## Prints the packages summary prompt.
  var finalPkgs: string
  var pkgLen: int

  for i in packages.split(" "):
    inc(pkgLen)
    var upstreamRunf: runFile
    let pkgRepo = findPkgRepo(i)
    if fileExists("/var/cache/kpkg/installed/"&i&"/run") and pkgRepo != "":
      upstreamRunf = parseRunfile(pkgRepo&"/"&i)
      if parseRunfile("/var/cache/kpkg/installed/"&i).versionString != upstreamRunf.versionString:
        finalPkgs = appendInternal(i&" -> ".green&upstreamRunf.versionString, finalPkgs)
        continue

    finalPkgs = appendInternal(i, finalPkgs)
  
  echo "Packages ("&($pkgLen)&"): "&finalPkgs

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

