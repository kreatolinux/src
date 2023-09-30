import os
import logger
import osproc
import streams

proc execCmdKpkg*(command: string): int =
  # Like execCmdEx, but with outputs.
  let process = startProcess(command, options = {poEvalCommand, poStdErrToStdOut})
  let outp = outputStream(process)
  var line: string

  while outp.readLine(line):
    echo line

  return waitForExit(process)

proc isRunningFromName(name: string): bool =
  # Allows you to check if it is running from name.
  # Ignores the current process.
  setCurrentDir("/proc")
  for i in walkDir("."):
    try:
      if readFile(i.path&"/comm") == name&"\n" and lastPathPart(i.path) != $getCurrentProcessId():
        
        debug "proc path: "&lastPathPart(i.path)
        debug $getCurrentProcessId()
        if symlinkExists(i.path):
          # Self check is for chroot, as the other check fails on chroot
          if lastPathPart(i.path) == "self" or lastPathPart(expandSymlink(i.path)) == $getCurrentProcessId():
            continue
        debug "returning true"
        return true
    except Exception:
      continue
  
  debug "returning false"
  return false

proc isKpkgRunning*() =
  if isRunningFromName("kpkg"):
      err("another instance of kpkg is running, will not proceed", false)
