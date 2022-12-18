import std/streams

## takes in a seq of packages and returns what to install
proc dephandler(pkgs: seq[string], repo: string): seq[string] =
    var deps: seq[string]
    try:
        for pkg in pkgs:
            if findPkgRepo(pkg) == "":
                err("Package "&pkg&" doesn't exist", false)
            for dep in openFileStream(repo&"/"&pkg&"/deps", fmRead).lines():
                if pkg in deps:
                    continue
                deps.add(dephandler(@[dep], repo))
                deps.add(dep)
        return deps
    except Exception:
        raise
