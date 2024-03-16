import os
import fuzzy
import strutils
import ../modules/config
import ../modules/sqlite
import ../modules/logger
import ../modules/colors
import ../modules/runparser

proc printResult(repo: string, package: string, colors = true): string =
    ## Prints results for searches.
    var r: string
    var isGroup = false
    var version: string
    var desc: string

    if packageExists(package):
        r = "i   "
        let pkg = getPackage(package, "/")
        isGroup = pkg.isGroup
        version = pkg.version
        desc = pkg.desc
    else:
        r = "ni  "
        let pkg = parseRunfile("/etc/kpkg/repos/"&repo&"/"&package)
        isGroup = pkg.isGroup
        version = pkg.version
        desc = pkg.desc

    if isGroup:
        
        if colors:
            r = cyanColor&"g"&resetColor&r
        else:
            r = "g"&r
    else:
        r = r&" "

    if colors:
        r = r&cyanColor&repo&resetColor&"/"&package&"-"&version
    else:
        r = r&repo&"/"&package&"-"&version
        
    
    for i in 1 .. 40 - (package.len + 1 + repo.len + version.len):
        r = r&" "

    if isEmptyOrWhitespace(desc):
        return r&"No description available"
    else:
        return r&desc

proc search*(keyword: seq[string], colors = true) =
    ## Search packages.
    if keyword.len == 0:
        err("please enter a keyword", false)

    let exactMatch = findPkgRepo(keyword[0])

    if exactMatch != "":
        echo "One exact match found."
        echo printResult(lastPathPart(exactMatch), keyword[0], colors)&"\n"


    echo "Other results;"

    for r in getConfigValue("Repositories", "repoDirs").split(" "):
        setCurrentDir(r)
        for i in walkDirs("*"):
            if (fuzzyMatchSmart(i, keyword[0]) >= 0.6 or fuzzyMatchSmart(
                    parseRunfile(r&"/"&i).desc, keyword.join(" ")) >= 0.8) and
                    i != keyword[0]:
                echo printResult(lastPathPart(r), i, colors)
