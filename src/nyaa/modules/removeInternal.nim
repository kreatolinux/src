proc removeInternal(package: string, root = ""): string =
    if not fileExists(root&"/etc/nyaa.installed/"&package&"/list_files"):
        err("package "&package&" is not installed", false)

    for line in lines root&"/etc/nyaa.installed/"&package&"/list_files":
        removeFile(root&"/"&line)
        if isEmptyOrWhitespace(toSeq(walkFiles(root&"/"&line)).join("")):
            removeDir(root&"/"&line)
    removeDir(root&"/etc/nyaa.installed/"&package)
    return "nyaa: package "&package&" removed."
