import os
import fuzzy
import strutils
import ../modules/config
import ../modules/logger
import ../modules/runparser

proc printResult(repo: string, package: string): string =
    ## Prints results for searches.
    var r: string
    var pkgrunf: runFile

    if dirExists("/var/cache/kpkg/installed/"&package):
        r = "i   "
        pkgrunf = parseRunfile("/var/cache/kpkg/installed/"&package)
    else:
        r = "ni  "
        pkgrunf = parseRunfile("/etc/kpkg/repos/"&repo&"/"&package)

    if pkgrunf.isGroup:
        r = "g"&r
    else:
        r = r&" "

    r = r&repo&"/"&package&"-"&pkgrunf.versionString

    
    for i in 1 .. 40 - (package.len + 1 + repo.len + pkgrunf.versionString.len):
        r = r&" "

    if isEmptyOrWhitespace(pkgrunf.desc):
        return r&"No description available"
    else:
        return r&pkgrunf.desc

proc search*(keyword: seq[string]) =
    ## Search packages.
    if keyword.len == 0:
        err("please enter a keyword", false)

    let exactMatch = findPkgRepo(keyword[0])

    if exactMatch != "":
        echo "One exact match found."
        echo printResult(lastPathPart(exactMatch), keyword[0])&"\n"


    echo "Other results;"

    for r in getConfigValue("Repositories", "repoDirs").split(" "):
        setCurrentDir(r)
        for i in walkDirs("*"):
            if (fuzzyMatchSmart(i, keyword[0]) >= 0.6 or fuzzyMatchSmart(
                    parseRunfile(r&"/"&i).desc, keyword.join(" ")) >= 0.8) and
                    i != keyword[0]:
                echo printResult(lastPathPart(r), i)
