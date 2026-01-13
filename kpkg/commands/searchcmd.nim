import os
import strutils
import ../modules/config
import ../modules/sqlite
import ../modules/logger
import ../modules/colors
import ../modules/runparser
import ../modules/fuzzyFinder

proc printResult(repo: string, package: string, colors = true): string =
  ## Prints results for searches.
  var r: string
  var isGroup = false
  var version: string
  var desc: string

  if packageExists(package):
    r = "i   "
    let pkg = getPackage(package, "/")
    isGroup = pkg.isGroup
    version = pkg.version
    desc = pkg.desc
  else:
    r = "ni  "
    let pkg = parseRunfile("/etc/kpkg/repos/"&repo&"/"&package)
    isGroup = pkg.isGroup
    version = pkg.version
    desc = pkg.desc

  if isGroup:

    if colors:
      r = cyanColor&"g"&resetColor&r
    else:
      r = "g"&r
  else:
    r = r&" "

  if colors:
    r = r&cyanColor&repo&resetColor&"/"&package&"-"&version
  else:
    r = r&repo&"/"&package&"-"&version


  for i in 1 .. 40 - (package.len + 1 + repo.len + version.len):
    r = r&" "

  if isEmptyOrWhitespace(desc):
    return r&"No description available"
  else:
    return r&desc

proc search*(keyword: seq[string], colors = true) =
  ## Search packages.
  if keyword.len == 0:
    error("please enter a keyword")
    quit(1)

  let exactMatch = findPkgRepo(keyword[0])

  if exactMatch != "":
    echo "One exact match found."
    echo printResult(lastPathPart(exactMatch), keyword[0], colors)&"\n"


  echo "Other results;"

  for r in getConfigValue("Repositories", "repoDirs").split(" "):
    setCurrentDir(r)
    for i in walkDirs("*"):
      if (fuzzyMatch(keyword[0], i) >= 0.6 or
              (parseRunfile(r&"/"&i).desc != "" and
              fuzzyMatch(keyword.join(" "), parseRunfile(r&"/"&i).desc) >=
                  0.8)) and
              i != keyword[0]:
          echo printResult(lastPathPart(r), i, colors)
