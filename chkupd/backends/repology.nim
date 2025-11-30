# chkupd v3 repology backend
import json, strutils, os, sets
import ../../kpkg/modules/runparser
import ../autoupdater
import ../../common/version
import httpclient

proc compareVersions(version1: string, version2: string, isSemver: bool): int =
    ## Compare two versions. Returns:
    ## -1 if version1 < version2
    ## 0 if version1 == version2
    ## 1 if version1 > version2
    if isSemver:
        let v1Split = split(version1, ".")
        let v2Split = split(version2, ".")
        
        # Compare MAJOR
        if v1Split[0] > v2Split[0]:
            return 1
        elif v1Split[0] < v2Split[0]:
            return -1
        
        # Compare MINOR if MAJOR is equal
        if v1Split.len > 1 and v2Split.len > 1:
            if v1Split[1] > v2Split[1]:
                return 1
            elif v1Split[1] < v2Split[1]:
                return -1
            
            # Compare PATCH if MINOR is equal
            if v1Split.len > 2 and v2Split.len > 2:
                if v1Split[2] > v2Split[2]:
                    return 1
                elif v1Split[2] < v2Split[2]:
                    return -1
        
        return 0
    else:
        try:
            let v1Int = parseInt(replace(version1, ".", ""))
            let v2Int = parseInt(replace(version2, ".", ""))
            if v1Int > v2Int:
                return 1
            elif v1Int < v2Int:
                return -1
            return 0
        except Exception:
            if version1 > version2:
                return 1
            elif version1 < version2:
                return -1
            return 0

proc repologyCheck*(package: string, repo: string, autoUpdate = false,
                skipIfDownloadFails = true, verbose = false) =
        ## DEPRECATED, use the new 'check' subcommand instead.
        # Check against Repology database.
        let pkgName = lastPathPart(package)
        var client = newHttpClient(userAgent="Klinux chkupd/"&ver&" (issuetracker: https://github.com/kreatolinux/src/issues)")
        var request = parseJson(client.getContent(
                        "https://repology.org/api/v1/project/"&pkgName))
        var version: string = ""
        let packageDir = repo&"/"&pkgName

        if verbose:
            echo "chkupd v3 Repology backend"

        if isEmptyOrWhitespace($request) or $request == "[]":
            echo "No package information found in Repology"
            return

        # First, parse the package to determine if it uses semver
        var pkg: runFile
        var isSemver = false
        try:
            pkg = parse_runfile(packageDir)
            isSemver = pkg.isSemver
        except Exception as e:
            echo "Couldn't parse package file: " & e.msg
            return

        # Collect all versions from entries with "newest" status
        # "newest" means it's the newest version in that repository,
        # so we collect all "newest" versions and find the maximum among them
        var allVersions: seq[string] = @[]
        var seenVersions = initHashSet[string]()
        var counter = 0
        
        while true:
            try:
                let entry = request[counter]
                let status = getStr(entry["status"])
                if status == "newest":
                    let entryVersion = getStr(entry["version"])
                    if entryVersion.len > 0 and not seenVersions.contains(entryVersion):
                        allVersions.add(entryVersion)
                        seenVersions.incl(entryVersion)
                        if verbose:
                            let repoName = try: getStr(entry["repo"]) except: "unknown"
                            echo "Found 'newest' version: " & entryVersion & " in " & repoName
                counter += 1
            except IndexError:
                break
            except Exception:
                counter += 1
                if counter >= len(request):
                    break

        if allVersions.len == 0:
            echo "No 'newest' versions found in Repology"
            return

        if verbose:
            echo "Collected " & $allVersions.len & " unique 'newest' versions"

        # Find the maximum version
        version = allVersions[0]
        for v in allVersions:
            if compareVersions(v, version, isSemver) > 0:
                version = v

        if verbose:
            echo "Selected maximum version: " & version

        var isOutdated = false
        var pkgRelease = pkg.release

        if "python" in pkg.deps:
            pkgRelease = pkg.release&"-"&parseRunfile(repo & "/python").version
        
        if verbose:
            echo "Current package version: " & pkg.version
            echo "Latest version found: " & version
            echo "Using semver comparison: " & $pkg.isSemver
        
        if pkg.isSemver:
            let pkgVerSplit = split(pkg.version, ".")
            let versionSplit = split(version, ".")

            # MAJOR
            if versionSplit[0] > pkgVerSplit[0]:
                isOutdated = true
            elif versionSplit[0] == pkgVerSplit[0]:
                # MINOR
                if versionSplit.len > 1 and pkgVerSplit.len > 1:
                    if versionSplit[1] > pkgVerSplit[1]:
                        isOutdated = true
                    elif versionSplit[1] == pkgVerSplit[1]:
                        # PATCH
                        if versionSplit.len > 2 and pkgVerSplit.len > 2:
                            if versionSplit[2] > pkgVerSplit[2]:
                                isOutdated = true
        else:
            try:
                let versionInt = parseInt(replace(version, ".", ""))
                let pkgVersionInt = parseInt(replace(pkg.version, ".", ""))

                if versionInt > pkgVersionInt:
                    isOutdated = true
            except Exception:
                if version > pkg.version:
                    isOutdated = true
        

        if verbose:
            echo "Package is outdated: " & $isOutdated
            echo "Current release: " & pkg.release & ", expected release: " & pkgRelease
        
        if autoUpdate:
                if pkg.release == pkgRelease and not isOutdated:
                    echo "Package is already up-to-date."
                    return
                else:
                    echo "Package is outdated. Updating..."
                    if not isOutdated:
                         version = pkg.version
                    
                    autoUpdater(pkg, packageDir, version, skipIfDownloadFails, pkgRelease)
        else:
            if verbose or isOutdated:
                echo "Latest version found: " & version
            if isOutdated:
                echo "Package is outdated (current: " & pkg.version & ", latest: " & version & ")"
            elif verbose:
                echo "Package is up-to-date (version: " & pkg.version & ")"
