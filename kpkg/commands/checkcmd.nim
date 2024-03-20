import os
import strutils
import ../modules/sqlite
import ../modules/logger
import ../modules/checksums

proc checkInternal(package: string, root: string, lines: seq[string], checkEtc: bool) =
    for line in lines:
        
        if dirExists(line):
            continue

        if line.parentDir().lastPathPart == "etc" and (not checkEtc):
            continue

        let splitted = line.split("=")
            
        if splitted.len < 2:
            #debug "'"&line&"' doesn't have checksum, skipping"
            continue
            
        let filePath = root&"/"&splitted[0].multiReplace(("\"", ""))
        if getSum(filePath, "b2") != splitted[1].multiReplace(("\"", "")):
            let errorOutput = "'"&filePath.relativePath(root)&"' has an invalid checksum, please reinstall '"&package&"'"
            when defined(release):
                err errorOutput
            else:
                debug errorOutput

proc check*(package = "", root = "/", silent = false, checkEtc = false) =
    ## Check packages in filesystem for errors.
    if not silent:
        info "the check may take a while, please wait"
    setCurrentDir(root)

    if isEmptyOrWhitespace(package):
        for pkg in getListPackages(root):
            checkInternal(pkg, root, getListFiles(pkg, root), checkEtc)
    else:
        if not packageExists(package, root):
            err("package '"&package&"' doesn't exist", false)
        else:
            checkInternal(package, root, getListFiles(package, root), checkEtc)
    
    if not silent:
        success("done")

