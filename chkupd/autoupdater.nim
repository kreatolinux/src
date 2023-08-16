import os
import strutils
import libsha/sha256
import ../kpkg/modules/runparser
import ../kpkg/modules/downloader

proc autoUpdater*(pkg: runFile, packageDir: string, newVersion: string,
                skipIfDownloadFails: bool) =
        # Autoupdates packages.
        echo "Autoupdating.."

        setCurrentDir("/tmp")
        var c = 0
        var source: string
        var filename: string

        for i in pkg.sha256sum.split(";"):
                source = pkg.sources.split(";")[c].replace(pkg.version, newVersion)
                filename = extractFilename(source).strip().replace(pkg.version, newVersion)

                # Download the source
                try:
                        download(source, filename)
                except Exception:
                        if skipIfDownloadFails:
                                echo "WARN: '"&pkg.pkg&"' failed because of download. Skipping."
                                return

                # Replace the sha256sum
                writeFile(packageDir&"/run", readFile(
                                packageDir&"/run").replace(pkg.sha256sum.split(
                                ";")[c], sha256hexdigest(readFile(
                                filename))&"  "&filename))
                c = c+1

                # Replace the version
                writeFile(packageDir&"/run", readFile(
                                packageDir&"/run").replace(pkg.version, newVersion))
                echo "Autoupdate complete. As always, you should check if the package does build or not."
