import regex
import os
include ../dephandler

proc builder(path: string): string =
  ## Builds the packages.
  const lockfile = "nyaa.lock"
  if fileExists(lockfile):
    echo "error: lockfile exists, will not proceed"
    quit(1)
  else:
    echo "nyaa: starting build"
    writeFile(lockfile, "") # Create lockfile
    # Build code here
    removeFile(lockfile)
    return "nyaa: build complete"

proc build(repo="/etc/nyaa", no=false, yes=false, packages: seq[string]): string =
  ## Build and install packages
  var deps: seq[string]
  var res: string

  if packages.len == 0:
    echo "error: please enter a package name"
    quit(1)

  for i in packages:
    if not dirExists(repo&"/"&i):
      echo "error: package `"&i&"` does not exist"
      quit(1)
    else:
      deps = deduplicate(dephandler(i, repo).split(" "))
      res = res & deps.join(" ") & " " & i

  echo "Packages:"&res

  if yes == true:
    for i in packages:
      return builder(repo&"/"&i)
  elif no == true:
    return "nyaa: exiting"
  else:
    stdout.write "Do you want to continue? (y/N) "
    var output = readLine(stdin)
    if output == "y" or output == "Y":
      for i in packages:
        return builder(repo&"/"&i)
    else:
      return "nyaa: exiting"

  # (?m)(?<=\bNAME=).*$
