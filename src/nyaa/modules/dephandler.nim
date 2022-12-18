import std/streams

## takes in a seq of packages and returns what to install
proc dephandler(pkgs: seq[string]): seq[string] =
    var deps: seq[string]
    try:
        for pkg in pkgs:
            let repo = findPkgRepo(pkg)
            if repo == "":
                err("Package "&pkg&" doesn't exist", false)
            
            if fileExists(repo&"/"&pkg&"/deps"):
              for dep in openFileStream(repo&"/"&pkg&"/deps", fmRead).lines():
                  if dep in deps or dep in pkgs:
                      continue
                  deps.add(dephandler(@[dep]))
                  deps.add(dep)
              return deps
    except Exception:
        raise
