import os
import strutils
import ../modules/config
import ../modules/sqlite
import ../modules/colors
import ../modules/runparser


proc printProvides(path, package: string, color: bool): string =
    # Prints provides prompt.
    let repo = findPkgRepo(package)
    var enableRunfile = true
    var finalResult = path&" @ "
    
    if isEmptyOrWhitespace(repo):
        enableRunfile = false
    
    if enableRunfile:    
        var pkgVer: string

        if packageExists(package, "/"):
            pkgVer = getPackage(package, "/").version
        else:
            pkgVer = parseRunfile("/etc/kpkg/repos/"&lastPathPart(repo)&"/"&package).versionString

        if color:
            finalResult = finalResult&cyanColor&lastPathPart(repo)&resetColor
        else:
            finalResult = finalResult&lastPathPart(repo)

        finalResult = finalResult&"/"&package&"-"&pkgVer
    else:
        finalResult = finalResult&package
    
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
                    echo printProvides(absolutePath(res), packageName, color)
                
