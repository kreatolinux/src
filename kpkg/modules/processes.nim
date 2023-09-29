import os
import logger
import streams

proc execCmdKpkg*(command: string): int =
  # Like execCmdEx, but with outputs.
  let process = startProcess(command, options = {poEvalCommand, poStdErrToStdOut})
  let outp = outputStream(process)
  var line: string

  while outp.readLine(line):
    echo line

proc isRunningFromName(name: string): bool =
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
