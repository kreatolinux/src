#import modules/chkroot

proc remove(packages: seq[string], destdir=""): string =
  ## Remove packages
  if packages.len == 0:
    err("please enter a package name", false)

  for i in packages:
    if not fileExists("/etc/nyaa.installed/"&i&"/list_files"):
      err("package "&i&" is not installed", false)
    else:
      for line in lines "/etc/nyaa.installed/"&i&"/list_files":
       # TODO: replace this with a Nim implementation
       discard execShellCmd("rm -f "&destdir&"/"&line&" 2>/dev/null")
       discard execShellCmd("[ -z \"$(ls -A "&destdir&"/"&line&" 2>/dev/null)\" ] && rm -rf "&destdir&"/"&line&" 2>/dev/null")
      return "Package "&i&" removed."
