proc isIn(one: seq[string], two: seq[string]): bool =
    ## Checks if a variable is in another.
    for i in one:
        if i in two:
            return true
    return false

proc dephandler(pkgs: seq[string], ignoreDeps = @["  "]): seq[string] =
    ## takes in a seq of packages and returns what to install.
    var deps: seq[string]
    try:
        for pkg in pkgs:
            let repo = findPkgRepo(pkg)
            if repo == "":
                err("Package "&pkg&" doesn't exist", false)

            if fileExists(repo&"/"&pkg&"/deps"):
                for dep in lines repo&"/"&pkg&"/deps":
                    if dep in pkgs or dep in deps or isIn(deps, ignoreDeps) or
                            dep in ignoreDeps:
                        continue

                    deps.add(dephandler(@[dep], deps&ignoreDeps))
                    deps.add(dep)

        return deps.filterit(it.len != 0)
    except Exception:
        raise
