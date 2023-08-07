import config
import logger
import sequtils
import strutils
import runparser

proc isIn(one: seq[string], two: seq[string]): bool =
    ## Checks if a variable is in another.
    for i in one:
        if i in two:
            return true
    return false

proc dephandler*(pkgs: seq[string], ignoreDeps = @["  "], bdeps = false): seq[string] =
    ## takes in a seq of packages and returns what to install.
    var deps: seq[string]
    try:
        for pkg in pkgs:
            var repo = findPkgRepo(pkg)
            if repo == "":
                err("Package "&pkg&" doesn't exist", false)

            let pkgrf = parse_runfile(repo&"/"&pkg)

            var pkgdeps: seq[string]

            if bdeps:
                pkgdeps = pkgrf.bdeps
            else:
                pkgdeps = pkgrf.deps

            if not isEmptyOrWhitespace(pkgdeps.join()):
                for dep in pkgdeps:
                    
                    repo = findPkgRepo(dep)

                    if repo == "":
                        err("Package "&dep&" doesn't exist", false)
                    
                    let deprf = parse_runfile(repo&"/"&dep)

                    if not isEmptyOrWhitespace(deprf.bdeps.join()):
                        deps.add(dephandler(@[dep], deps&ignoreDeps, bdeps = true))

                    if dep in pkgs or dep in deps or isIn(deps, ignoreDeps) or
                            dep in ignoreDeps:
                        continue

                    deps.add(dephandler(@[dep], deps&ignoreDeps, bdeps = false))

                    deps.add(dep)

        return deps.filterit(it.len != 0)
    except CatchableError:
        raise
