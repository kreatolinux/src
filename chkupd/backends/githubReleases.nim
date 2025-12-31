# chkupd v3 githubReleases backend
import json, strutils, os
import ../../kpkg/modules/run3/run3
import ../autoupdater
import ../../common/version
import httpclient

proc githubReleasesCheck*(package: string, repo: string,
                githubReleasesRepo: string, autoUpdate = false,
                skipIfDownloadFails = true, trimString = "", verbose = false) =
  # Check against GitHub Releases.
  let pkgName = lastPathPart(package)
  var client = newHttpClient(userAgent = "Klinux chkupd/"&ver&" (issuetracker: https://github.com/kreatolinux/src/issues)")
  var version = $(parseJson(client.getContent(
                  "https://api.github.com/repos/"&githubReleasesRepo&"/releases/latest"))["tag_name"])

  if not isEmptyOrWhitespace(trimString):
    version = replace(version, trimString, "")


  version = replace(version, "'", "")
  version = replace(version, "\"", "")

  var counter = 0
  let packageDir = repo&"/"&pkgName
  var newestOrNot: string

  if verbose:
    echo "chkupd v3 GitHub Releases backend"
    echo "Repository: " & githubReleasesRepo
    echo "Latest release tag: " & version


  if isEmptyOrWhitespace(version):
    return

  var isOutdated = false
  let pkg = parseRun3(packageDir)
  let pkgVersion = pkg.getVersion()
  var pkgRelease = pkg.getRelease()
  let pkgDeps = pkg.getDepends()
  let isSemverStr = pkg.getVariable("is_semver")
  let isSemver = isSemverStr.toLowerAscii() in ["true", "1", "yes", "y", "on"]

  if "python" in pkgDeps:
    pkgRelease = pkgRelease&"-"&parseRun3(repo &
                    "/python").getVersion()

  if isSemver:
    if verbose:
      echo "Package is using semver."
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
    if verbose:
      echo "Package is not using semver."
    try:
      let versionInt = parseInt(replace(version, ".", ""))
      let pkgVersionInt = parseInt(replace(pkgVersion, ".", ""))

      if versionInt > pkgVersionInt:
        isOutdated = true
    except Exception:
      if version > pkgVersion:
        isOutdated = true


  if autoUpdate:
    if pkg.getRelease() == pkgRelease and not isOutdated:
      echo "Package is already up-to-date."
      return
    else:
      echo "Package is outdated. Updating..."
      if not isOutdated:
        version = pkgVersion

    autoUpdater(pkg, absolutePath(packageDir), version,
                    skipIfDownloadFails, pkgRelease)

    return
  else:
    if verbose or isOutdated:
      echo "Latest version found: " & version
    if isOutdated:
      echo "Package is outdated (current: " & pkgVersion &
                      ", latest: " & version & ")"
    elif verbose:
      echo "Package is up-to-date (version: " & pkgVersion & ")"
