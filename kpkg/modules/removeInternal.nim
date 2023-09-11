import os
import logger
import strutils
import sequtils
import runparser
import commonTasks

proc removeInternal*(package: string, root = "",
        installedDir = root&"/var/cache/kpkg/installed",
        ignoreReplaces = false) =

    let init = getInit(root)

    if dirExists(installedDir&"/"&package&"-"&init):
        removeInternal(package&"-"&init, root, installedDir, ignoreReplaces)

    var actualPackage: string

    if symlinkExists(installedDir&"/"&package):
        actualPackage = expandSymlink(installedDir&"/"&package)
    else:
        actualPackage = package

    if not fileExists(installedDir&"/"&actualPackage&"/list_files"):
        err("package "&package&" is not installed", false)

    for line in lines installedDir&"/"&actualPackage&"/list_files":
        discard tryRemoveFile(root&"/"&line)

        if isEmptyOrWhitespace(toSeq(walkDirRec(root&"/"&line)).join("")):
            removeDir(root&"/"&line)

    if not ignoreReplaces:
        let pkgreplaces = parse_runfile(installedDir&"/"&actualPackage).replaces
        for i in pkgreplaces:
            if symlinkExists(installedDir&"/"&i):
                removeFile(installedDir&"/"&i)

    removeDir(installedDir&"/"&package)
