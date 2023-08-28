import os
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

proc checkVersions(root: string, dependency: string, repo: string, split = @[
        "<=", ">=", "<", ">", "="]): string =
    ## Internal proc for checking versions on dependencies (if it exists)

    for i in split:
        if i in dependency:

            let dSplit = dependency.split(i)
            var deprf: runFile

            if dirExists(root&"/var/cache/kpkg/installed/"&dependency):
                deprf = parse_runfile(root&"/var/cache/kpkg/installed/"&dSplit[0])
            else:
                deprf = parse_runfile(repo&"/"&dSplit[0])

            const errName = "required dependency version not found"

            case i:
                of "<=":
                    if not (deprf.versionString <= dSplit[1]):
                        err(errName, false)
                of ">=":
                    if not (deprf.versionString >= dSplit[1]):
                        err(errName, false)
                of "<":
                    if not (deprf.versionString < dSplit[1]):
                        err(errName, false)
                of ">":
                    if not (deprf.versionString > dSplit[1]):
                        err(errName, false)
                of "=":
                    if deprf.versionString != dSplit[1]:
                        err(errName, false)

            return dSplit[0]

    return dependency


proc dephandler*(pkgs: seq[string], ignoreDeps = @["  "], bdeps = false,
        isBuild = false, root: string, prevPkgName = ""): seq[string] =
    ## takes in a seq of packages and returns what to install.

    var deps: seq[string]

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
        
      if pkgdeps.len == 0:
        continue
      
      if not isEmptyOrWhitespace(pkgdeps.join()):
        for dep in pkgdeps:
          
          if prevPkgName == dep:
            if isBuild:
              err("circular dependency detected", false)
            else:
              return deps.filterit(it.len != 0)

        if pkgdeps.len == 0:
            continue

        if not isEmptyOrWhitespace(pkgdeps.join()):
            for dep in pkgdeps:

                if prevPkgName == dep:
                    err("circular dependency detected", false)

                let d = checkVersions(root, dep, repo)

                repo = findPkgRepo(d)

                if repo == "":
                    err("Package "&d&" doesn't exist", false)

                let deprf = parse_runfile(repo&"/"&d)

                if not isEmptyOrWhitespace(deprf.bdeps.join()) and isBuild:
                    deps.add(dephandler(@[d], deps&ignoreDeps, bdeps = true,
                            isBuild = true, root = root, prevPkgName = pkg))

                if d in pkgs or d in deps or isIn(deps, ignoreDeps) or dep in ignoreDeps:
                    continue

                deps.add(dephandler(@[d], deps&ignoreDeps, bdeps = false,
                        isBuild = isBuild, root = root, prevPkgName = pkg))

                deps.add(d)

    return deps.filterit(it.len != 0)
