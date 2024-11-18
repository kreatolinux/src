# chkupd v3 repology backend
import json, strutils, os
import ../../kpkg/modules/runparser
import ../autoupdater
import ../../common/version
import httpclient

proc repologyCheck*(package: string, repo: string, autoUpdate = false,
                skipIfDownloadFails = true) =
        ## Check against Repology database.
        let pkgName = lastPathPart(package)
        var client = newHttpClient(userAgent="Klinux chkupd/"&ver&" (issuetracker: https://github.com/kreatolinux/src/issues)")
        var request = parseJson(client.getContent(
                        "https://repology.org/api/v1/project/"&pkgName))
        var counter = 0
        var version: string
        let packageDir = repo&"/"&pkgName
        var newestOrNot: string

        echo "chkupd v3 Repology backend"

        while true:

                if isEmptyOrWhitespace($request) or $request == "[]":
                        break
                try:
                        newestOrNot = getStr(request[counter]["status"])
                except Exception:
                        echo "Couldn't get package version, skipping"
                        break

                if newestOrNot == "newest":
                        version = getStr(request[counter]["version"])
                        var isOutdated = false
                        let pkg = parse_runfile(packageDir)
                        var pkgRelease = pkg.release

                        if "python" in pkg.deps:
                            pkgRelease = pkg.release&"-"&parseRunfile(repo & "/python").version
                        
                        if pkg.isSemver:
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
                            try:
                                let versionInt = parseInt(replace(version, ".", ""))
                                let pkgVersionInt = parseInt(replace(pkg.version, ".", ""))

                                if versionInt > pkgVersionInt:
                                    isOutdated = true
                            except Exception:
                                if version > pkg.version:
                                    isOutdated = true
                        

                        if autoUpdate:
                                if pkg.release == pkgRelease or not isOutdated:
                                    echo "Package is already up-to-date."
                                    return
                                else:
                                    echo "Package is outdated. Updating..."
                                    if not isOutdated:
                                         version = pkg.version
                                
                                autoUpdater(pkg, packageDir, version, skipIfDownloadFails, pkgRelease)

                        return
                else:
                        counter = counter+1
