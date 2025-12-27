import os
import logger
import osproc
import streams
import strutils
import commonPaths

proc execCmdKpkg*(command: string, error = "none", silentMode = false): tuple[
    output: string, exitCode: int] =
  # Like execCmdKpkg, but captures output instead of printing (unless not silent).
  debug "execCmdKpkg: command: "&command
  let process = startProcess(command, options = {poEvalCommand,
      poStdErrToStdOut})
  var line: string
  var output = ""

  let outp = outputStream(process)
  while outp.readLine(line):
    output.add(line & "\n")
    if not silentMode:
      echo line

  let res = waitForExit(process)

  if error != "none" and res != 0:
    err error&" failed"

  return (output.strip(), res)

proc getPidKpkg(): string =
  # Gets current pid from /proc/self.
  return lastPathPart(expandSymlink("/proc/self"))

proc isRunningFromName(name: string): bool =
  # Allows you to check if it is running from name.
  # Ignores the current process.
  setCurrentDir("/proc")
  for i in walkDir("."):
    try:
      if readFile(i.path&"/comm") == name&"\n" and lastPathPart(i.path) !=
          getPidKpkg():

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

proc execEnv*(command: string, error = "none", passthrough = false,
        silentMode = false, path = kpkgMergedPath, remount = false,
        asRoot = false): tuple[
        output: string, exitCode: int] =
  ## Wrapper of execCmdKpkg and Bubblewrap that runs a command in the sandbox and captures output.
  ## If asRoot is true, runs as root inside sandbox (needed for postinstall scripts).
  ## If asRoot is false (default), runs as non-root user (needed for build scripts like configure).
  const localeEnvPrefix = "LC_ALL=C.UTF-8 LC_CTYPE=C.UTF-8 LANG=C.UTF-8 "
  debug "execEnv: entered with path=" & path & ", passthrough=" & $passthrough &
      ", asRoot=" & $asRoot
  if passthrough:
    return execCmdKpkg(localeEnvPrefix&"/bin/sh -c \""&command.replace("\"", "\\\"")&"\"", error,
            silentMode = silentMode)
  else:
    debug "execEnv: checking if path exists: " & path
    if not dirExists(path):
      err("internal: you have to use mountOverlay() before running execEnv")

    if remount and path == kpkgMergedPath:
      discard execCmdKpkg("mount -o remount "&path,
              silentMode = silentMode)

    # Create dirs so that bwrap doesn't complain
    debug "execEnv: creating dirs"
    createDir(kpkgTempDir1)
    createDir(kpkgTempDir2)
    discard existsOrCreateDir(kpkgCacheDir)
    discard existsOrCreateDir(kpkgSourcesDir)

    # Create bind target directories inside the sandbox path if they don't exist
    debug "execEnv: creating bind target dirs in sandbox"
    debug "execEnv: creating " & path & kpkgTempDir1
    createDir(path & kpkgTempDir1)
    debug "execEnv: creating " & path & kpkgTempDir2
    createDir(path & kpkgTempDir2)
    debug "execEnv: creating " & path & "/etc/kpkg/repos"
    try:
      createDir(path & "/etc/kpkg/repos")
    except OSError as e:
      debug "execEnv: OSError creating " & path & "/etc/kpkg/repos: " & e.msg
      raise
    except CatchableError as e:
      debug "execEnv: CatchableError creating " & path & "/etc/kpkg/repos: " & e.msg
      raise
    debug "execEnv: creating " & path & kpkgSourcesDir
    createDir(path & kpkgSourcesDir)

    debug "execEnv: about to run bwrap with path: " & path & ", command: " & command

    # Use --unshare-user for non-root builds (to satisfy configure scripts that refuse to run as root)
    # Skip it for postinstall scripts that need root to modify system directories
    let userNsOpts = if asRoot: "" else: "--unshare-user --uid 1000 --gid 1000 "

    return execCmdKpkg(localeEnvPrefix&"bwrap "&userNsOpts&"--bind "&path&" / --bind "&kpkgTempDir1&" "&kpkgTempDir1&" --bind /etc/kpkg/repos /etc/kpkg/repos --bind "&kpkgTempDir2&" "&kpkgTempDir2&" --bind "&kpkgSourcesDir&" "&kpkgSourcesDir&" --dev /dev --proc /proc --perms 1777 --tmpfs /dev/shm --ro-bind /etc/resolv.conf /etc/resolv.conf /bin/sh -c \""&command.replace("\"", "\\\"")&"\"",
            error, silentMode = silentMode)
