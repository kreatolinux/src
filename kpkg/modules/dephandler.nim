import os
import config
import logger
import sequtils
import strutils
import runparser
import commonTasks

proc checkVersions(root: string, dependency: string, repo: string, split = @[
        "<=", ">=", "<", ">", "="]): seq[string] =
    ## Internal proc for checking versions on dependencies (if it exists)

    for i in split:
        if i in dependency:

            let dSplit = dependency.split(i)
            var deprf: runFile

            if dirExists(root&"/var/cache/kpkg/installed/"&dSplit[0]):
                deprf = parseRunfile(root&"/var/cache/kpkg/installed/"&dSplit[0])
            else:
                deprf = parseRunfile(repo&"/"&dSplit[0])

            let warnName = "Required dependency version for "&dSplit[
                    0]&" not found, upgrading"
            let errName = "Required dependency version for "&dSplit[
                    0]&" not found on repositories, cannot continue"


            case i:
                of "<=":
                    if not (deprf.versionString <= dSplit[1]):
                        if dirExists(root&"/var/cache/kpkg/installed/"&dSplit[0]):
                            warn(warnName)
                            return @["upgrade", dSplit[0]]
                        else:
                            err(errName, false)
                of ">=":
                    if not (deprf.versionString >= dSplit[1]):
                        if dirExists(root&"/var/cache/kpkg/installed/"&dSplit[0]):
                            warn(warnName)
                            return @["upgrade", dSplit[0]]
                        else:
                            err(errName, false)
                of "<":
                    if not (deprf.versionString < dSplit[1]):
                        if dirExists(root&"/var/cache/kpkg/installed/"&dSplit[0]):
                            warn(warnName)
                            return @["upgrade", dSplit[0]]
                        else:
                            err(errName, false)
                of ">":
                    if not (deprf.versionString > dSplit[1]):
                        if dirExists(root&"/var/cache/kpkg/installed/"&dSplit[0]):
                            warn(warnName)
                            return @["upgrade", dSplit[0]]
                        else:
                            err(errName, false)
                of "=":
                    if deprf.versionString != dSplit[1]:
                        if dirExists(root&"/var/cache/kpkg/installed/"&dSplit[0]):
                            warn(warnName)
                            return @["upgrade", dSplit[0]]
                        else:
                            err(errName, false)

            return @["noupgrade", dSplit[0]]

    return @["noupgrade", dependency]


proc dephandler*(pkgs: seq[string], ignoreDeps = @["  "], bdeps = false,
        isBuild = false, root: string, prevPkgName = "",
                forceInstallAll = false, chkInstalledDirInstead = false): seq[string] =
    ## takes in a seq of packages and returns what to install.

    var deps: seq[string]
    let init = getInit(root)

    for pkg in pkgs:
        var repo: string

        if not chkInstalledDirInstead:
            repo = findPkgRepo(pkg)
        else:
            repo = root&"/var/cache/kpkg/installed"

        if repo == "":
            err("Package "&pkg&" doesn't exist", false)

        let pkgrf = parseRunfile(repo&"/"&pkg)
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
                    if isBuild and not dirExists(
                            "/var/cache/kpkg/installed/"&dep):
                        err("circular dependency detected", false)
                    else:
                        return deps.filterit(it.len != 0)


                let chkVer = checkVersions(root, dep, repo)
                let d = chkVer[1]

                if fileExists(root&"/var/cache/kpkg/installed/"&d&"/list_files") and chkVer[
                        0] != "upgrade" and not forceInstallAll:
                    debug "dephandler: '"&root&"/var/cache/kpkg/installed/"&d&"/list_files' exist, continuing"
                    continue

                repo = findPkgRepo(d)

                if repo == "":
                    err("Package "&d&" doesn't exist", false)

                if findPkgRepo(dep&"-"&init) != "":
                    deps.add(dep&"-"&init)

                let deprf = parseRunfile(repo&"/"&d)

                if not isEmptyOrWhitespace(deprf.bdeps.join()) and isBuild:
                    deps.add(dephandler(@[d], deps&ignoreDeps, bdeps = true,
                            isBuild = true, root = root, prevPkgName = pkg,
                                    forceInstallAll = forceInstallAll))

                if d in deps or d in ignoreDeps:
                    continue

                deps.add(dephandler(@[d], deps&ignoreDeps, bdeps = false,
                        isBuild = isBuild, root = root, prevPkgName = pkg,
                                forceInstallAll = forceInstallAll))

                deps.add(d)

    return deduplicate(deps.filterit(it.len != 0))
