# chkupd v3 repology backend
import json, strutils, os, sets
import ../../kpkg/modules/run3/run3
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
        try:
            let v1Major = parseInt(v1Split[0])
            let v2Major = parseInt(v2Split[0])
            if v1Major > v2Major:
                return 1
            elif v1Major < v2Major:
                return -1
        except ValueError:
            # Fallback to string comparison if parsing fails
            if v1Split[0] > v2Split[0]:
                return 1
            elif v1Split[0] < v2Split[0]:
                return -1

        # Compare MINOR if MAJOR is equal
        if v1Split.len > 1 and v2Split.len > 1:
            try:
                let v1Minor = parseInt(v1Split[1])
                let v2Minor = parseInt(v2Split[1])
                if v1Minor > v2Minor:
                    return 1
                elif v1Minor < v2Minor:
                    return -1
            except ValueError:
                if v1Split[1] > v2Split[1]:
                    return 1
                elif v1Split[1] < v2Split[1]:
                    return -1

            # Compare PATCH if MINOR is equal
            if v1Split.len > 2 and v2Split.len > 2:
                try:
                    let v1Patch = parseInt(v1Split[2])
                    let v2Patch = parseInt(v2Split[2])
                    if v1Patch > v2Patch:
                        return 1
                    elif v1Patch < v2Patch:
                        return -1
                except ValueError:
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
    var client = newHttpClient(userAgent = "Klinux chkupd/"&ver&" (issuetracker: https://github.com/kreatolinux/src/issues)")
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
    var pkg: Run3File
    var isSemver = false
    try:
        pkg = parseRun3(packageDir)
        let isSemverStr = pkg.getVariable("is_semver")
        isSemver = isSemverStr.toLowerAscii() in ["true", "1", "yes", "y", "on"]
    except Exception as e:
        echo "Couldn't parse package file: " & e.msg
        return

    # Collect all versions from entries with "newest" status
    # "newest" means it's the newest version in that repository,
    # so we collect all "newest" versions and find the maximum among them
    var allVersions: seq[string] = @[]
    var seenVersions = initHashSet[string]()
    var counter = 0

    let pkgVersion = pkg.getVersion()
    let pkgDeps = pkg.getDepends()
    var pkgRelease = pkg.getRelease()

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
                        var repoName = "unknown"
                        try:
                            repoName = getStr(entry["repo"])
                        except:
                            discard
                        echo "Found 'newest' version: " & entryVersion &
                                " in " & repoName
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

    # Track the expected release (with python version suffix if applicable)
    # This is used for comparison only, not for updating the file
    var expectedRelease = pkgRelease

    if verbose:
        echo "Current package version: " & pkgVersion
        echo "Latest version found: " & version
        echo "Using semver comparison: " & $isSemver

    if isSemver:
        let pkgVerSplit = split(pkgVersion, ".")
        let versionSplit = split(version, ".")

        # MAJOR
        try:
            let vMajor = parseInt(versionSplit[0])
            let pkgMajor = parseInt(pkgVerSplit[0])
            if vMajor > pkgMajor:
                isOutdated = true
            elif vMajor == pkgMajor:
                # MINOR
                if versionSplit.len > 1 and pkgVerSplit.len > 1:
                    let vMinor = parseInt(versionSplit[1])
                    let pkgMinor = parseInt(pkgVerSplit[1])
                    if vMinor > pkgMinor:
                        isOutdated = true
                    elif vMinor == pkgMinor:
                        # PATCH
                        if versionSplit.len > 2 and pkgVerSplit.len > 2:
                            let vPatch = parseInt(versionSplit[2])
                            let pkgPatch = parseInt(pkgVerSplit[2])
                            if vPatch > pkgPatch:
                                isOutdated = true
        except ValueError:
            # Fallback to string comparison if parsing fails
            if versionSplit[0] > pkgVerSplit[0]:
                isOutdated = true
            elif versionSplit[0] == pkgVerSplit[0]:
                if versionSplit.len > 1 and pkgVerSplit.len > 1:
                    if versionSplit[1] > pkgVerSplit[1]:
                        isOutdated = true
                    elif versionSplit[1] == pkgVerSplit[1]:
                        if versionSplit.len > 2 and pkgVerSplit.len > 2:
                            if versionSplit[2] > pkgVerSplit[2]:
                                isOutdated = true
    else:
        try:
            let versionInt = parseInt(replace(version, ".", ""))
            let pkgVersionInt = parseInt(replace(pkgVersion, ".", ""))

            if versionInt > pkgVersionInt:
                isOutdated = true
        except Exception:
            if version > pkgVersion:
                isOutdated = true


    if verbose:
        echo "Package is outdated: " & $isOutdated
        echo "Current release: " & pkgRelease & ", expected release: " & expectedRelease

    if autoUpdate:
        if expectedRelease == pkgRelease and not isOutdated:
            echo "Package is already up-to-date."
            return
        else:
            echo "Package is outdated. Updating..."
            if not isOutdated:
                version = pkgVersion

            # Only pass release to autoupdater if version is not outdated
            # (meaning we're only rebuilding due to dependency change)
            # In that case, don't modify the release in the file at all
            autoUpdater(pkg, packageDir, version, skipIfDownloadFails)
    else:
        if verbose or isOutdated:
            echo "Latest version found: " & version
        if isOutdated:
            echo "Package is outdated (current: " & pkgVersion & ", latest: " &
                    version & ")"
        elif verbose:
            echo "Package is up-to-date (version: " & pkgVersion & ")"
