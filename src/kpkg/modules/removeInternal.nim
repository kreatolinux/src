proc removeInternal(package: string, root = ""): string =
    if not fileExists(root&"/var/cache/kpkg/installed/"&package&"/list_files"):
        err("package "&package&" is not installed", false)

    for line in lines root&"/var/cache/kpkg/installed/"&package&"/list_files":
        discard tryRemoveFile(root&"/"&line)

        if isEmptyOrWhitespace(toSeq(walkDirRec(root&"/"&line)).join("")):
            removeDir(root&"/"&line)

    removeDir(root&"/var/cache/kpkg/installed/"&package)
    return "nyaa: package "&package&" removed."
