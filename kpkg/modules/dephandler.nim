import os
import config
import sqlite
import logger
import sequtils
import strutils
import runparser
import commonTasks


proc isIn(one, two: seq[string]): bool =
    for i in one:
        if i in two:
            return true
    return false

proc packageToRunFile(package: Package): runFile =
    # Converts package to runFile. Not all variables are available.
    return runFile(pkg: package.name, version: package.version, versionString: package.version, release: package.release, epoch: package.epoch, deps: package.deps.split("!!k!!"), bdeps: package.bdeps.split("!!k!!"))

proc checkVersions(root: string, dependency: string, repo: string, split = @[
        "<=", ">=", "<", ">", "="]): seq[string] =
    ## Internal proc for checking versions on dependencies (if it exists)

    for i in split:
        if i in dependency:

            let dSplit = dependency.split(i)
            var deprf: string

            if packageExists(dSplit[0], root):
                deprf = getPackage(dSplit[0], root).version
            else:
                var r = repo

                if repo == "local":
                    r = findPkgRepo(r)
                
                debug "parseRunfile ran, checkVersions"
                deprf = parseRunfile(r&"/"&dSplit[0]).versionString

            let warnName = "Required dependency version for "&dSplit[
                    0]&" not found, upgrading"
            let errName = "Required dependency version for "&dSplit[
                    0]&" not found on repositories, cannot continue"


            case i:
                of "<=":
                    if not (deprf <= dSplit[1]):
                        if packageExists(dSplit[0], root):
                            warn(warnName)
                            return @["upgrade", dSplit[0]]
                        else:
                            err(errName, false)
                of ">=":
                    if not (deprf >= dSplit[1]):
                        if packageExists(dSplit[0], root):
                            warn(warnName)
                            return @["upgrade", dSplit[0]]
                        else:
                            err(errName, false)
                of "<":
                    if not (deprf < dSplit[1]):
                        if packageExists(dSplit[0], root):
                            warn(warnName)
                            return @["upgrade", dSplit[0]]
                        else:
                            err(errName, false)
                of ">":
                    if not (deprf > dSplit[1]):
                        if packageExists(dSplit[0], root):
                            warn(warnName)
                            return @["upgrade", dSplit[0]]
                        else:
                            err(errName, false)
                of "=":
                    if deprf != dSplit[1]:
                        if packageExists(dSplit[0], root):
                            warn(warnName)
                            return @["upgrade", dSplit[0]]
                        else:
                            err(errName, false)

            return @["noupgrade", dSplit[0]]

    return @["noupgrade", dependency]



var replaceList: seq[tuple[package: string, replacedBy: seq[string]]]

proc dephandler*(pkgs: seq[string], ignoreDeps = @["  "], bdeps = false,
        isBuild = false, root: string, prevPkgName = "",
                forceInstallAll = false, chkInstalledDirInstead = false, isInstallDir = false, ignoreInit = false): seq[string] =
    ## takes in a seq of packages and returns what to install.
    

    var deps: seq[string]
    var init: string
    
    if not ignoreInit:
        init = getInit(root)

    for p in pkgs:
        
        var pkg = p

        let pkgSplit = p.split("/")
        var repo: string
        
        if isInstallDir:
            repo = absolutePath(pkg).parentDir()
            pkg = lastPathPart(pkg)
        else:
            if pkgSplit.len > 1:
                repo = "/etc/kpkg/repos/"&pkgSplit[0]
                pkg = pkgSplit[1]
            elif not chkInstalledDirInstead:
                repo = findPkgRepo(pkg)
            else:
                repo = "local"

        if repo == "":
            err("Package '"&pkg&"' doesn't exist", false)
        elif not dirExists(repo) and repo != "local":
            err("The repository '"&repo&"' doesn't exist", false)
        elif not fileExists(repo&"/"&pkg&"/run") and repo != "local":
            err("The package '"&pkg&"' doesn't exist on the repository "&repo, false)
        
        
        var pkgrf: runFile

        if repo != "local":
            debug "parseRunfile ran, dephandler"
            pkgrf = parseRunfile(repo&"/"&pkg)
        else:
            pkgrf = packageToRunfile(getPackage(pkg, root))

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
                    if isBuild and not packageExists(dep, "/"):
                        err("circular dependency detected for '"&dep&"'", false)
                    else:
                        return deps.filterit(it.len != 0)


                let chkVer = checkVersions(root, dep, repo)
                let d = chkVer[1]

                if packageExists(d, root) and chkVer[
                        0] != "upgrade" and not forceInstallAll:
                    debug "dephandler: package '"&d&"' exist in the db, continuing"
                    continue
                
                if not chkInstalledDirInstead:
                    repo = findPkgRepo(d)

                if repo == "":
                    err("Package "&d&" doesn't exist", false)

                var deprf: runFile

                if repo == "local":
                    deprf = pkgrf
                else:
                    debug "parseRunfile ran, dephandler 2"
                    deprf = parseRunfile(repo&"/"&d)                
                
                if d in deps or d in ignoreDeps or isIn(deprf.replaces, deps):
                    continue

                if not ignoreInit:
                    if findPkgRepo(dep&"-"&init) != "":
                        deps.add(dep&"-"&init)
                
                var dontAdd = false

                for i in replaceList:
                    if i.package == d or d in i.replacedBy:
                        dontAdd = true
                        

                if deprf.replaces.len > 0 and not dontAdd:
                    replaceList = replaceList&(dep, deprf.replaces)
                
                if not isEmptyOrWhitespace(deprf.bdeps.join()) and isBuild:
                    deps.add(dephandler(@[d], deprf.replaces&deps&ignoreDeps, bdeps = true,
                            isBuild = true, root = root, prevPkgName = pkg, chkInstalledDirInstead = chkInstalledDirInstead, forceInstallAll = forceInstallAll, ignoreInit = ignoreInit))

                deps.add(dephandler(@[d], deprf.replaces&deps&ignoreDeps, bdeps = false,
                        isBuild = isBuild, root = root, prevPkgName = pkg, chkInstalledDirInstead = chkInstalledDirInstead,
                                forceInstallAll = forceInstallAll, ignoreInit = ignoreInit))

                deps.add(d)

    for i in replaceList:
        debug "replaceList: '"&replaceList.join(" ")&"'"
        for replacePackage in i.replacedBy:
            if not (replacePackage in deps):
                
                while deps.find(replacePackage) != -1:
                    let index = deps.find(replacePackage)
                    debug "deleting '"&replacePackage&"'"
                    deps.delete(index)
                    debug "inserting '"&i.package&"' instead"
                    deps.insert(i.package, index)
 
    return deduplicate(deps.filterit(it.len != 0))
