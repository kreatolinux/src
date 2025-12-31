import os
import strutils
import regex
import ../kpkg/modules/checksums
import ../kpkg/modules/run3/run3
import ../kpkg/modules/downloader

proc escapeRegex(s: string): string =
  ## Escape special regex characters in a string
  result = ""
  for c in s:
    case c
    of '.', '^', '$', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '\\':
      result.add('\\')
      result.add(c)
    else:
      result.add(c)

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
  let newSources = pkg.getSourcesWithVersion(newVersion)
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
    source = newSources[c]
    filename = extractFilename(source).strip()

    # Download the source
    try:
      download(source, filename, raiseWhenFail = true)
    except Exception as e:
      if skipIfDownloadFails:
        echo "WARN: '"&pkgName&"' failed because of download. Skipping."
        return
      else:
        echo "ERROR: '"&pkgName&"' failed because of download: " & e.msg
        raise

    # Replace the sum
    writeFile(packageDir&"/"&runFileName, readFile(
                    packageDir&"/"&runFileName).replace(splitSum[c],
                    getSum(filename, sumType)))
    c = c+1

  # Replace the version (only the version: line to avoid corrupting other fields)
  # Handle both quoted and unquoted version values
  let versionPattern = "^(version:\\s*\"?)" & escapeRegex(version) & "(\"?)"
  var content = readFile(packageDir&"/"&runFileName)
  content = content.replace(re2(versionPattern, {regexMultiline}), "${1}" &
      newVersion & "${2}")
  writeFile(packageDir&"/"&runFileName, content)

  # Replace the release (only the release: line to avoid corrupting other fields)
  if not isEmptyOrWhitespace(release):
    let releasePattern = "^(release:\\s*\"?)" & escapeRegex(pkgRelease) & "(\"?)"
    content = readFile(packageDir&"/"&runFileName)
    content = content.replace(re2(releasePattern, {regexMultiline}), "${1}" &
        release & "${2}")
    writeFile(packageDir&"/"&runFileName, content)
    echo "Autoupdate complete. As always, you should check if the package does build or not."
