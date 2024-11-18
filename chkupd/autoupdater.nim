import os
import strutils
import ../kpkg/modules/checksums
import ../kpkg/modules/runparser
import ../kpkg/modules/downloader

proc autoUpdater*(pkg: runFile, packageDir: string, newVersion: string,
                skipIfDownloadFails: bool, release: string = "") =
        # Autoupdates packages.
        echo "Autoupdating.."

        setCurrentDir("/tmp")
        var c = 0
        var source: string
        var filename: string
        
        var splitSum: seq[string]
        var sumType: string

        if not isEmptyOrWhitespace(pkg.b2sum):
            splitSum = pkg.b2sum.split(" ")
            sumType = "b2"
        elif not isEmptyOrWhitespace(pkg.sha512sum):
            splitSum = pkg.sha512sum.split(" ")
            sumType = "sha512"
        elif not isEmptyOrWhitespace(pkg.sha256sum):
            splitSum = pkg.sha256sum.split(" ")
            sumType = "sha256"

        for i in splitSum:
                source = pkg.sources.split(" ")[c].replace(pkg.version, newVersion)
                filename = extractFilename(source).strip().replace(pkg.version, newVersion)

                # Download the source
                try:
                        download(source, filename, raiseWhenFail = true)
                except Exception:
                        if skipIfDownloadFails:
                                echo "WARN: '"&pkg.pkg&"' failed because of download. Skipping."
                                return

                # Replace the sum
                writeFile(packageDir&"/run", readFile(packageDir&"/run").replace(splitSum[c], getSum(filename, sumType)))
                c = c+1

                # Replace the version
                writeFile(packageDir&"/run", readFile(
                                packageDir&"/run").replace(pkg.version, newVersion))

				# Replace the release (if it exists)
				if not isEmptyOrWhitespace(release):
						writeFile(packageDir&"/run", readFile(
								packageDir&"/run").replace(pkg.release, release))
                echo "Autoupdate complete. As always, you should check if the package does build or not."
