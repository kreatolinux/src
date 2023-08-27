import os
import logger
import strutils
import sequtils
import runparser

proc removeInternal*(package: string, root = "",
        installedDir = "/var/cache/kpkg/installed",
        ignoreReplaces = false): string =

    var actualPackage: string

    if symlinkExists(root&"/var/cache/kpkg/installed/"&package):
        actualPackage = expandSymlink(root&installedDir&"/"&package)
    else:
        actualPackage = package

    if not fileExists(root&installedDir&"/"&actualPackage&"/list_files"):
        err("package "&package&" is not installed", false)

    for line in lines root&installedDir&"/"&actualPackage&"/list_files":
        discard tryRemoveFile(root&"/"&line)

        if isEmptyOrWhitespace(toSeq(walkDirRec(root&"/"&line)).join("")):
            removeDir(root&"/"&line)

    removeDir(root&installedDir&"/"&package)

    if not ignoreReplaces:
        let pkgreplaces = parse_runfile(
                root&installedDir&"/"&actualPackage).replaces
        for i in pkgreplaces:
            removeDir(root&installedDir&"/"&i)

    return "kpkg: package "&package&" removed."
