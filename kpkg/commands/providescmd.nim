import os
import strutils
import ../modules/config
import ../modules/sqlite
import ../modules/colors
import ../modules/runparser


proc printProvides*(path = "", package: string, color: bool, enablePath = true): string =
    # Prints provides prompt.
    var repo = findPkgRepo(package)
    var finalResult = ""
    if enablePath:
        finalResult = path&" @ "
    
    var pkgVer: string

    if packageExists(package, "/"):
        pkgVer = getPackage(package, "/").version
    else:
        pkgVer = parseRunfile("/etc/kpkg/repos/"&lastPathPart(repo)&"/"&package).versionString
        
    if isEmptyOrWhitespace(repo):
        repo = "local"
    else:
        repo = lastPathPart(repo)

    if color:
        finalResult = finalResult&blueColor&repo&resetColor
    else:
        finalResult = finalResult&repo

    finalResult = finalResult&"/"&package

    if color:
        finalResult = finalResult&cyanColor&"#"&resetColor&pkgVer
    else:
        finalResult = finalResult&"#"&pkgVer
    
    return finalResult

proc provides*(files: seq[string], color = true) =
    ## List packages that contains a file.
    setCurrentDir("/")
    for file in files:
        for packageName in getListPackages("/"):
            for line in getListFiles(packageName, "/"):
                if relativePath(file, "/") in line:
                    var res = line
                    normalizePath(res)
                    echo printProvides(absolutePath(res), packageName, color, false)
                
