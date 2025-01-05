# chkupd v3 arch backend
import os
import json
import httpclient
import ../../kpkg/modules/runparser
import ../autoupdater

proc archCheck*(package: string, repo: string, autoUpdate = false,
                skipIfDownloadFails = true) =
        ## DEPRECATED, use 'check' subcommand instead.
        # Check against Arch repositories.
        let pkgName = lastPathPart(package)
        var client = newHttpClient()
        var version: string
        let packageDir = repo&"/"&pkgName

        try:
                version = getStr(parseJson(client.getContent(
                                "https://archlinux.org/packages/search/json/?name="&pkgName))[
                                "results"][0]["pkgver"])
        except Exception:
                echo "Package doesn't seem to exist on Arch repositories, skipping"
                return

        echo "chkupd v3 Arch backend"

        let pkg = parse_runfile(packageDir)
        echo "local version: "&pkg.version
        echo "remote version: "&version

        if version > pkg.versionString:
                echo "Package is not uptodate."

                if autoUpdate:
                        autoUpdater(pkg, packageDir, version, skipIfDownloadFails)
        return
