proc removeInternal(package: string, root = ""): string =
    if not fileExists("/etc/nyaa.installed/"&package&"/list_files"):
      err("package "&package&" is not installed", false)

    for line in lines root&"/etc/nyaa.installed/"&package&"/list_files":
      # TODO: replace this with a Nim implementation
      discard execShellCmd("rm -f "&root&"/"&line&" 2>/dev/null")
      discard execShellCmd("[ -z \"$(ls -A "&root&"/"&line&" 2>/dev/null)\" ] && rm -rf "&root&"/"&line&" 2>/dev/null")
    removeDir(root&"/etc/nyaa.installed/"&package)
    return "Package "&package&" removed."
