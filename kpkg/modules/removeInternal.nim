import os
import logger
import strutils
import sequtils
import runparser

proc removeInternal*(package: string, root = ""): string =

    var actualPackage: string
    
    if symlinkExists(root&"/var/cache/kpkg/installed/"&package):
        actualPackage = expandSymlink(root&"/var/cache/kpkg/installed/"&package)
    else:
        actualPackage = package

    let pkgreplaces = parse_runfile(root&"/var/cache/kpkg/installed/"&actualPackage).replaces

    if not fileExists(root&"/var/cache/kpkg/installed/"&actualPackage&"/list_files"):
        err("package "&package&" is not installed", false)

    for line in lines root&"/var/cache/kpkg/installed/"&actualPackage&"/list_files":
        discard tryRemoveFile(root&"/"&line)

        if isEmptyOrWhitespace(toSeq(walkDirRec(root&"/"&line)).join("")):
            removeDir(root&"/"&line)

    removeDir(root&"/var/cache/kpkg/installed/"&package)

    for i in pkgreplaces:
        removeDir(root&"/var/cache/kpkg/installed/"&i)

    return "kpkg: package "&package&" removed."
