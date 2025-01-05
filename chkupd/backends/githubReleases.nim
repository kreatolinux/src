# chkupd v3 githubReleases backend
import json, strutils, os
import ../../kpkg/modules/runparser
import ../autoupdater
import ../../common/version
import httpclient

proc githubReleasesCheck*(package: string, repo: string, githubReleasesRepo: string, autoUpdate = false, skipIfDownloadFails = true, trimString = "") =
        ## Check against Repology database.
        let pkgName = lastPathPart(package)
        var client = newHttpClient(userAgent="Klinux chkupd/"&ver&" (issuetracker: https://github.com/kreatolinux/src/issues)")
        var version = $(parseJson(client.getContent("https://api.github.com/repos/"&githubReleasesRepo&"/releases/latest"))["tag_name"])

        if not isEmptyOrWhitespace(trimString):
                version = replace(version, trimString, "")


        version = replace(version, "'", "")
        version = replace(version, "\"", "")

        var counter = 0
        let packageDir = repo&"/"&pkgName
        var newestOrNot: string

        echo "chkupd v3 GitHub Releases backend"
        

        if isEmptyOrWhitespace(version):
            return

        var isOutdated = false
        let pkg = parse_runfile(packageDir)
        var pkgRelease = pkg.release

        if "python" in pkg.deps:
            pkgRelease = pkg.release&"-"&parseRunfile(repo & "/python").version
                        
        if pkg.isSemver:
            echo "Package is using semver."
            let pkgVerSplit = split(pkg.version, ".")
            let versionSplit = split(version, ".")

            # MAJOR
            if versionSplit[0] > pkgVerSplit[0]:
                isOutdated = true
            elif versionSplit[0] == pkgVerSplit[0]:
                # MINOR
                if versionSplit[1] > pkgVerSplit[1]:
                    isOutdated = true
                elif versionSplit[1] == pkgVerSplit[1]:
                    # PATCH
                    if versionSplit[2] > pkgVerSplit[2]:
                        isOutdated = true
        else:
            echo "Package is not using semver."
            try:
                let versionInt = parseInt(replace(version, ".", ""))
                let pkgVersionInt = parseInt(replace(pkg.version, ".", ""))
                
                if versionInt > pkgVersionInt:
                    isOutdated = true
            except Exception:
                if version > pkg.version:
                    isOutdated = true
                        

        if autoUpdate:
                if pkg.release == pkgRelease and not isOutdated:
                    echo "Package is already up-to-date."
                    return
                else:
                    echo "Package is outdated. Updating..."
                    if not isOutdated:
                        version = pkg.version
                                
                autoUpdater(pkg, absolutePath(packageDir), version, skipIfDownloadFails, pkgRelease)

                return
        else:
                counter = counter+1
