import os
import strutils
import times
import ../modules/cveparser
import ../modules/runparser
import ../modules/logger
import ../modules/downloader
import norm/[model, sqlite]

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
    let runf = parseRunfile(runfPath, removeLockfileWhenErr = false)
    var packageVulns = @[newVulnerability()]
    dbConn.select(packageVulns, "vulnerability.package = ? LIMIT 10", lastPathPart(runfPath)) # TODO: get name from runFile AUDIT_NAME variable, etc.
    for vuln in packageVulns:
        for version in vuln.versionEndExcluding.split("::"):
            if verChecker(runf.version, version) or runf.version >= version:
                continue
            elif version != "false":
                info "vulnerability found in package '"&lastPathPart(runfPath)&"', "&vuln.cve 
                    
                if description:
                    echo "\nDescription of '"&vuln.cve&"': \n\n"&vuln.description.strip()&"\n"
 
                break


proc audit*(package: seq[string], description = false, fetch = false, fetchBinary = false) = # TODO: binary = true on release
    ## Check vulnerabilities in installed packages.
    
    const dbPath = "/var/cache/kpkg/vulns.db"

    if not fileExists("/var/cache/kpkg/vulns.db") and not fetch:
        err("Vulnerability database doesn't exist. Please create one using `kpkg audit --fetch`.", false)

    if fetch and not isAdmin():
        err("you have to be root for this action.", false)
    
    if fetch:
        removeFile(dbPath)

    let dbConn = open(dbPath, "", "", "")

    if fetch:
        # TODO: do sqlite database downloads.
        if not fetchBinary:

            removeFile("/var/cache/kpkg/vulns.json")
            setCurrentDir("/var/cache/kpkg")

            # I use fkie-cad/nvd-json-data-feeds since it makes collecting the data really simple.
            download("https://github.com/fkie-cad/nvd-json-data-feeds/releases/latest/download/CVE-"&($year(now()))&".json.xz", "/var/cache/kpkg/vulns.json.xz")
            
            if execShellCmd("xz -d vulns.json.xz") != 0:
                err("Couldn't extract compressed file, is `xz` installed?", false)
            
            success("'"&($updateVulns(dbConn, "/var/cache/kpkg/vulns.json", true))&"' vulnerabilities parsed.", true)
            removeFile("/var/cache/kpkg/vulns.json.xz")
            removeFile("/var/cache/kpkg/vulns.json")

    if not fileExists("/var/cache/kpkg/vulns.db"):
        err("Vulnerability database doesn't exist. Please create one using `kpkg audit --fetch`.", false)

    if isEmptyOrWhitespace(package.join("")):
        for i in walkDirs("/var/cache/kpkg/installed/*"):
            vulnChecker(lastPathPart(i), i, dbConn, description)
    else:
        for i in package:
            vulnChecker(i, "/var/cache/kpkg/installed/"&i, dbConn, description)
            