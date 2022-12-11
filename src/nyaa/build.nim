import os
import osproc
import strutils
import libsha/sha256
import puppy
include modules/dephandler

proc builder(path: string, root="/tmp/nyaa_build", srcdir="/tmp/nyaa_srcdir"): string =
  ## Builds the packages.
  
  const lockfile = "nyaa.lock"
  
  if fileExists(lockfile):
    echo "error: lockfile exists, will not proceed"
    quit(1)
  else:
    echo "nyaa: starting build"
    
    #writeFile(lockfile, "") # Create lockfile
    
    # Actual building start here
    
    # Remove directories if they exist
    removeDir(root)
    removeDir(srcdir)

    # Create required directories
    createDir(root) 
    createDir(srcdir)

    # Enter into the source directory
    setCurrentDir(srcdir)
    
    var vars: seq[string]
    var pkg: string
    var sources: string
    var version: string
    var sha256sum: string
    
    for i in lines path&"/run":
      vars = i.split("=")
      case vars[0]:
        of "NAME":
          pkg = vars[1].replace("\"", "")
        of "SOURCES":
          sources = vars[1].replace("\"", "")
        of "VERSION":
          version = vars[1].replace("\"", "")
        of "SHA256SUM":
          sha256sum = vars[1].replace("\"", "")
      
      if "()" in vars[0]:
        break
    
    var filename: string
    var existsPrepare = execShellCmd(". "&path&"/run"&" && command -v prepare")
    
    for i in sources.split(";"):
      filename = extractFilename(i.replace("$VERSION", version))
      writeFile(filename, fetch(i.replace("$VERSION", version)))
      if sha256hexdigest(readAll(open(filename)))&"  "&filename != sha256sum:
        echo "error: sha256sum doesn't match"
        quit(1)
      if existsPrepare != 0:
        discard execProcess("bsdtar -xvf "&filename)

    if existsPrepare == 0:
      assert execShellCmd(". "&path&"/run"&" && prepare") == 0, "prepare failed"
    
    assert execShellCmd(". "&path&"/run"&" && export DESTDIR="&root&" && export ROOT=$DESTDIR && build") == 0, "build failed"

    #removeFile(lockfile)
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

  # 
