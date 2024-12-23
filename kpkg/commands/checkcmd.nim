import os
import strutils
import ../modules/sqlite
import ../modules/logger
import ../modules/checksums

proc checkInternal(package: Package, root: string, lines = getFilesPackage(package, root), checkEtc: bool) =
    for line in lines:
        
        let actPath = line.path.replace("\"", "")
        let fullPath = root&"/"&actPath

        if dirExists(fullPath):
            continue

        if actPath.parentDir().lastPathPart == "etc" and (not checkEtc):
            continue

        if line.blake2Checksum == "":
            #debug "'"&line&"' doesn't have checksum, skipping"
            continue
            
        let sum = line.blake2Checksum
        let actualSum = getSum(fullPath, "b2")

        debug "checking '"&fullPath.relativePath(root)&"' with checksum '"&sum&"' and actual checksum '"&actualSum&"'"

        if actualSum != sum:
            let errorOutput = "'"&fullPath.relativePath(root)&"' has an invalid checksum, please reinstall '"&package.name&"'"
            debug errorOutput
            if not isDebugMode():
                err errorOutput

proc check*(package = "", root = "/", silent = false, checkEtc = false) =
    ## Check packages in filesystem for errors.
    if not silent:
        info "the check may take a while, please wait"
    setCurrentDir(root)

    if isEmptyOrWhitespace(package):
        for pkg in getListPackages(root):
            let p = getPackage(package, root)
            checkInternal(p, root, getFilesPackage(p, root), checkEtc)
    else:
        if not packageExists(package, root):
            err("package '"&package&"' doesn't exist", false)
        else:
            let p = getPackage(package, root)
            checkInternal(p, root, getFilesPackage(p, root), checkEtc)
    
    if not silent:
        success("done")

