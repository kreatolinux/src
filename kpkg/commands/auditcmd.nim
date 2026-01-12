import os
import strutils
import times
import ../modules/cveparser
import ../modules/sqlite
import ../modules/downloader
import ../modules/libarchive
import norm/sqlite
import ../modules/logger as kpkgLogger

proc verChecker*(ver1, ver2: string): bool =
  # Check version, and return true if ver1 >= ver2.
  let ver1Split = ver1.split(".")
  let ver2Split = ver2.split(".")
  if ver1Split.len == ver2Split.len and ver1Split.len >= 3:
    for count in 0..ver1Split.len:
      # MAJOR.MINOR.PATCH
      if ver1Split[count] >= ver2Split[count]:
        return true

  return false

proc vulnChecker(package, runfPath: string, dbConn: DbConn, description: bool) =
  let pkgLocal = getPackage(package, "/")
  var packageVulns = @[newVulnerability()]
  dbConn.select(packageVulns, "vulnerability.package = ?",
          package) # TODO: get name from runFile AUDIT_NAME variable, etc.
  for vuln in packageVulns:
    for version in vuln.versionEndExcluding.split("::"):
      if verChecker(pkgLocal.version, version) or pkgLocal.version >= version:
        continue
      elif version != "false":
        kpkgLogger.info "vulnerability found in package '"&package&"', "&vuln.cve

        if description:
          echo "\nDescription of '"&vuln.cve&"': \n\n"&vuln.description.strip()&"\n"

        break


proc audit*(package: seq[string], description = false, fetch = false,
        fetchBinary = true) = # TODO: binary = true on release
  ## Check vulnerabilities in installed packages.

  const dbPath = "/var/cache/kpkg/vulns.db"

  if not fileExists("/var/cache/kpkg/vulns.db") and not fetch:
    kpkgLogger.error("Vulnerability database doesn't exist. Please create one using `kpkg audit --fetch`.")
    quit(1)

  if fetch and not isAdmin():
    kpkgLogger.error("you have to be root for this action.")
    quit(1)

  if fetch:
    removeFile(dbPath)

  let dbConn = open(dbPath, "", "", "")

  if fetch:
    removeFile("/var/cache/kpkg/vulns.json")
    setCurrentDir("/var/cache/kpkg")

    if not fetchBinary:
      # I use fkie-cad/nvd-json-data-feeds since it makes collecting the data really simple.
      download("https://github.com/fkie-cad/nvd-json-data-feeds/releases/latest/download/CVE-"&(
              $year(now()))&".json.xz", "/var/cache/kpkg/vulns.json.xz")

      if execShellCmd("xz -d vulns.json.xz") != 0:
        kpkgLogger.error("Couldn't extract compressed file, is `xz` installed?")
        quit(1)

      kpkgLogger.info("'"&($updateVulns(dbConn, "/var/cache/kpkg/vulns.json",
              true))&"' vulnerabilities parsed.")
      removeFile("/var/cache/kpkg/vulns.json.xz")
      removeFile("/var/cache/kpkg/vulns.json")
    else:
      download("https://nightly.link/kreatolinux/src/workflows/build-db/master/vulndb.zip", "/var/cache/kpkg/vulndb.zip")
      discard extract("/var/cache/kpkg/vulndb.zip")
      kpkgLogger.info("Vulnerability database installed.")
      removeFile("/var/cache/kpkg/vulndb.zip")

    return


  if not fileExists("/var/cache/kpkg/vulns.db"):
    kpkgLogger.error("Vulnerability database doesn't exist. Please create one using `kpkg audit --fetch`.")
    quit(1)

  if isEmptyOrWhitespace(package.join("")):
    for i in walkDirs("/var/cache/kpkg/installed/*"):
      vulnChecker(lastPathPart(i), i, dbConn, description)
  else:
    for i in package:
      vulnChecker(i, "/var/cache/kpkg/installed/"&i, dbConn, description)

