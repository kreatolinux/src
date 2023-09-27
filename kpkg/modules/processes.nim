import os
import logger

proc isRunningFromName*(name: string): bool =
  # Allows you to check if it is running from name.
  # Ignores the current process.
  setCurrentDir("/proc")
  for i in walkDir("."):
    try:
      if readFile(i.path&"/comm") == name&"\n" and lastPathPart(i.path) != $getCurrentProcessId():
        
        if symlinkExists(i.path):
          if lastPathPart(expandSymlink(i.path)) == $getCurrentProcessId():
            continue
        
        return true
    except Exception:
      continue
  
  return false

proc isKpkgRunning*() =
  if isRunningFromName("kpkg"):
      err("another instance of kpkg is running, will not proceed", false)
