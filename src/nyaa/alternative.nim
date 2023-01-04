proc set_alternative(package: string, to: string, runFile: runFile): string =
  ## Sets an alternative.
  ## The way of setting an alternative is defined on repo/package/altFile .
  ## See nyaa_alternative(8) for how to write an altFile.
  let pkg = findPkgRepo(package)&"/"&package

  if dirExists("/etc/nyaa.alternatives/"&package):
    err("package is already set to a alternative", false)

  if dirExists("/etc/nyaa.installed/"&runFile.pkg):
    if execShellCmd(". "&pkg&"/altFile && "&to) != 0:
      err("alternative script failed", false)
    else:
      createSymlink("/etc/nyaa.installed/"&runFile.pkg,
          "/etc/nyaa.installed/"&to)
      discard existsOrCreateDir("/etc/nyaa.alternatives/")
      createDir("/etc/nyaa.alternatives/"&package)
      writeFile("/etc/nyaa.alternatives/"&package&"/altTo", to)
      return "nyaa: set "&package&" to "&to
  else:
    err("package is not installed", false)

proc unset_alternative(package: string, runFile: runFile): string =
  ## Unsets an alternative.
  let pkg = findPkgRepo(package)&"/"&package
  let altTo = readAll(open("/etc/nyaa.alternatives/"&package&"/altTo"))
  if dirExists("/etc/nyaa.installed/"&altTo):
    removeDir("/etc/nyaa.installed/"&altTo) # TODO: FIX THIS
    removeDir("/etc/nyaa.alternatives/"&package)
    return "nyaa: unset "&package
  else:
    err("package isn't set to any alternative", false)

proc get_alternative(package: runFile, actualPkgName: string) =
  ## Gets alternatives.
  if package.alternativeTo != "":
    echo "Package "&package.pkg&" can used for alternatives to;"
    echo package.alternativeTo
    echo "You can do 'nyaa --set "&actualPkgName&" alternativeName' to set it as one."

    if fileExists("/etc/nyaa.alternatives/"&actualPkgName&"/altTo"):
      echo "Package "&package.pkg&" is currently set as a alternative to "&readAll(
          open("/etc/nyaa.alternatives/"&actualPkgname&"/altTo"))
  else:
    echo "This package can't be used/set as a alternative to anything."

proc alternative(set = false, unset = false, get = false, package: seq[string]) =
  ## Allows you to manage alternatives.
  var pkg: runFile

  try:
    pkg = parse_runfile(findPkgRepo(package[0])&"/"&package[0], false)
  except Exception:
    err("not enough arguments (see nyaa alternative --help)", false)


  # I know what you are thinking, i should use cases but for some reason it gives me a build error when i do that. -kreatoo
  if get == true:
    get_alternative(pkg, package[0])
  elif set == true:
    try:
      echo set_alternative(package[0], package[1], pkg)
    except Exception:
      err("--set requires 2 arguments (eg. nyaa alternative --set coreutils busybox)", false)
  elif unset == true:
    echo unset_alternative(package[0], pkg)
  else:
    err("you have to choose an option (see nyaa alternative --help)", false)
