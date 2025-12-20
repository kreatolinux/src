import os
import strutils
import ../kpkg/modules/checksums
import ../kpkg/modules/run3/run3
import ../kpkg/modules/downloader

proc autoUpdater*(pkg: Run3File, packageDir: string, newVersion: string,
                skipIfDownloadFails: bool, release: string = "") =
  # Autoupdates packages.
  echo "Autoupdating.."

  setCurrentDir("/tmp")
  var c = 0
  var source: string
  var filename: string

  var splitSum: seq[string]
  var sumType: string

  let b2sum = pkg.getB2sum()
  let sha512sum = pkg.getSha512sum()
  let sha256sum = pkg.getSha256sum()
  let sources = pkg.getSources()
  let version = pkg.getVersion()
  let pkgRelease = pkg.getRelease()
  let pkgName = pkg.getName()

  if b2sum.len > 0:
    splitSum = b2sum
    sumType = "b2"
  elif sha512sum.len > 0:
    splitSum = sha512sum
    sumType = "sha512"
  elif sha256sum.len > 0:
    splitSum = sha256sum
    sumType = "sha256"

  var runFileName = "run3"
  if not fileExists(packageDir & "/run3") and fileExists(packageDir & "/run"):
    runFileName = "run"

  for i in splitSum:
    source = sources[c].replace(version, newVersion)
    filename = extractFilename(source).strip().replace(version, newVersion)

    # Download the source
    try:
      download(source, filename, raiseWhenFail = true)
    except Exception:
      if skipIfDownloadFails:
        echo "WARN: '"&pkgName&"' failed because of download. Skipping."
        return

    # Replace the sum
    writeFile(packageDir&"/"&runFileName, readFile(
                    packageDir&"/"&runFileName).replace(splitSum[c],
                    getSum(filename, sumType)))
    c = c+1

    # Replace the version
    writeFile(packageDir&"/"&runFileName, readFile(
                    packageDir&"/"&runFileName).replace(version, newVersion))

    # Replace the release (if it exists)
    if not isEmptyOrWhitespace(release):
      writeFile(packageDir&"/"&runFileName, readFile(
             packageDir&"/"&runFileName).replace(pkgRelease, release))
    echo "Autoupdate complete. As always, you should check if the package does build or not."
