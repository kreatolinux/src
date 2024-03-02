import os
import sequtils
import strutils
import ../modules/logger
import ../modules/checksums
import ../modules/commonPaths

proc checkInternal(root, file: string, checkEtc: bool) =
    for line in lines file:
        
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
            let errorOutput = "'"&filePath.relativePath(root)&"' has an invalid checksum, please reinstall '"&lastPathPart(file.parentDir())&"'"
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
        for file in toSeq(walkFiles(root&kpkgInstalledDir&"/*/list_files")):
            checkInternal(root, file, checkEtc)
    else:
        if not fileExists(root&kpkgInstalledDir&"/"&package&"/list_files"):
            err("package '"&package&"' doesn't exist", false)
        else:
            checkInternal(root, root&kpkgInstalledDir&"/"&package&"/list_files", checkEtc)
    
    if not silent:
        success("done")

