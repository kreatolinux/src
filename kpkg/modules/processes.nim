import os
import logger
import osproc
import streams

proc execCmdKpkg*(command: string, error = "none", silentMode = false): int =
  # Like execCmdEx, but with outputs.
  debug "execCmdKpkg: command: "&command
  let process = startProcess(command, options = {poEvalCommand, poStdErrToStdOut})
  var line: string
  
  if not silentMode:
    let outp = outputStream(process)
    while outp.readLine(line):
        echo line

  let res = waitForExit(process)

  if error != "none" and res != 0:
    err error&" failed"
  
  return res

proc getPidKpkg(): string =
  # Gets current pid from /proc/self.
  return lastPathPart(expandSymlink("/proc/self"))

proc isRunningFromName(name: string): bool =
  # Allows you to check if it is running from name.
  # Ignores the current process.
  setCurrentDir("/proc")
  for i in walkDir("."):
    try:
      if readFile(i.path&"/comm") == name&"\n" and lastPathPart(i.path) != getPidKpkg():
        
        debug "proc path: "&lastPathPart(i.path)
        debug getPidKpkg()
        if symlinkExists(i.path):
          if lastPathPart(expandSymlink(i.path)) == getPidKpkg():
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
