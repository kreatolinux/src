proc set_alternative(package: string, to: string, runFile: runFile): string =
  ## Sets an alternative.
  ## The way of setting an alternative is defined on repo/package/altFile .
  ## See nyaa_alternative(8) for how to write an altFile.
  let pkg = findPkgRepo(package)&"/"&package

  if dirExists("/etc/nyaa.installed/"&runFile.pkg):
    if execShellCmd(". "&pkg&"/altFile && "&to) != 0:
      err("alternative script failed", false)
    else:
      createSymlink("/etc/nyaa.installed/"&runFile.pkg,
          "/etc/nyaa.installed/"&to)
      return "nyaa: set "&package&" to "&to
  else:
    err("package is not installed", false)

proc get_alternative(package: runFile, actualPkgName: string) =
  ## Gets alternatives.
  if package.alternativeTo != "":
    echo "Package "&package.pkg&" can used for alternatives to;"
    echo package.alternativeTo
    echo "You can do 'nyaa --set "&actualPkgName&" alternativeName' to set it as one."
  else:
    echo "This package can't be used/set as a alternative to anything."

proc alternative(set = false, get = false, package: seq[string]) =
  ## Allows you to manage alternatives.
  var pkg: runFile

  try:
    pkg = parse_runfile(findPkgRepo(package[0])&"/"&package[0], false)
  except Exception:
    err("not enough arguments (see nyaa alternative --help)", false)

  if get == true:
    get_alternative(pkg, package[0])
  elif set == true:
    try:
      echo set_alternative(package[0], package[1], pkg)
    except Exception:
      err("--set requires 2 arguments (eg. nyaa alternative --set coreutils busybox)", false)
  else:
    err("you have to choose an option (see nyaa alternative --help)", false)
