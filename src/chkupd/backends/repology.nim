# chkupd v3 repology backend
import json, strutils, os, libsha/sha256
include ../../kpkg/modules/logger
include ../../kpkg/modules/downloader
include ../../kpkg/modules/runparser

proc repologyCheck(package: string, repo: string, autoUpdate = false,
                skipIfDownloadFails = true) =
        ## Check against Repology database.
        let pkgName = lastPathPart(package)
        var client = newHttpClient()
        var request = parseJson(client.getContent(
                        "https://repology.org/api/v1/project/"&pkgName&"?repos_newest=1&newest=1"))
        var counter = 0
        var version: string
        let packageDir = repo&"/"&pkgName

        echo "chkupd v3 Repology backend"

        while true:

                if isEmptyOrWhitespace($request) or $request == "[]":
                        break

                if $request[counter]["status"] == "\"newest\"":
                        version = multiReplace($request[counter]["version"], (
                                        "\"", ""), ("'", ""))
                        let pkg = parse_runfile(packageDir)
                        echo "local version: "&pkg.version
                        echo "remote version: "&version

                        if version > pkg.versionString:
                                echo "Package is not uptodate."

                                if autoUpdate:
                                        echo "Autoupdating.."

                                        setCurrentDir("/tmp")

                                        var c = 0
                                        var source: string
                                        var filename: string

                                        for i in pkg.sha256sum.split(";"):

                                                source = pkg.sources.split(";")[
                                                                c].replace(
                                                                pkg.version, version)
                                                filename = extractFilename(
                                                                source).strip().replace(
                                                                pkg.version, version)

                                                # Download the source
                                                try:
                                                        waitFor download(source, filename)
                                                except Exception:
                                                        if skipIfDownloadFails:
                                                                echo "WARN: '"&pkgName&"' failed because of download. Skipping."
                                                                return

                                                # Replace the sha256sum
                                                writeFile(packageDir&"/run",
                                                                readFile(
                                                                packageDir&"/run").replace(
                                                                pkg.sha256sum.split(
                                                                ";")[c],
                                                                sha256hexdigest(
                                                                readFile(
                                                                filename))&"  "&filename))
                                                c = c+1

                                        # Replace the version
                                        writeFile(packageDir&"/run", readFile(
                                                        packageDir&"/run").replace(
                                                        pkg.version, version))
                                        echo "Autoupdate complete. As always, you should check if the package does build or not."

                        return
                else:
                        counter = counter+1
