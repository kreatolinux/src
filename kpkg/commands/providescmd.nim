import os
import strutils
import ../modules/config
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
        var pkgrunf: runFile

        if dirExists("/var/cache/kpkg/installed/"&package):
            pkgrunf = parseRunfile("/var/cache/kpkg/installed/"&package)
        else:
            pkgrunf = parseRunfile("/etc/kpkg/repos/"&lastPathPart(repo)&"/"&package)

        if color:
            finalResult = finalResult&cyanColor&lastPathPart(repo)&resetColor
        else:
            finalResult = finalResult&lastPathPart(repo)

        finalResult = finalResult&"/"&package&"-"&pkgrunf.versionString
    else:
        finalResult = finalResult&package
    
    return finalResult

proc provides*(files: seq[string], color = true) =
    ## List packages that contains a file.
    setCurrentDir("/")
    for file in files:
        for listFiles in walkFiles("/var/cache/kpkg/installed/*/list_files"):
            for line in lines listFiles:
                if relativePath(file, "/") in line:
                    var res = line
                    let pkg = relativePath(listFiles, "/var/cache/kpkg/installed/").replace("/list_files", "")
                    normalizePath(res)
                    echo printProvides(absolutePath(res), pkg, color)
                