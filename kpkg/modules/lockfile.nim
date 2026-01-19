import os
import strutils
import posix
import ../../common/logging

const lockfilePath* = "/tmp/kpkg.lock"

proc getCurrentPid(): int =
  ## Get current process ID using POSIX getpid()
  result = int(getpid())

proc isProcessRunning(pid: int): bool =
  ## Check if process with given PID is still running
  when defined(linux):
    # Check if /proc/{pid} exists
    return dirExists("/proc/" & $pid)
  else:
    # On non-Linux (macOS, BSD), use kill with signal 0 to check
    # Signal 0 doesn't send anything but checks if process exists
    return kill(Pid(pid), 0) == 0 or errno == EPERM

proc removeLockfile*() =
  ## Remove the lockfile if it exists
  if fileExists(lockfilePath):
    removeFile(lockfilePath)

proc lockfileErrorCallback(msg: string) =
  ## Error callback that removes lockfile on fatal errors
  info("lockfile", "removing lockfile due to error")
  removeLockfile()

proc createLockfile*() =
  ## Create lockfile with PID and set up error callback
  let pid = getCurrentPid()
  writeFile(lockfilePath, $pid)
  setErrorCallback(lockfileErrorCallback)

proc checkLockfile*() =
  ## Check if lockfile exists. Auto-removes stale locks from dead processes.
  if fileExists(lockfilePath):
    try:
      let content = readFile(lockfilePath).strip()
      if content != "":
        let pid = parseInt(content)
        if isProcessRunning(pid):
          error("lockfile exists (PID " & $pid & " is running), will not proceed")
          quit(1)
        else:
          # Process is dead - stale lock, auto-remove
          warn("lockfile", "removing stale lockfile from dead process " & $pid)
          removeLockfile()
      else:
        # Empty lockfile (old format) - treat as stale
        warn("lockfile", "removing stale lockfile (empty, old format)")
        removeLockfile()
    except ValueError:
      # Invalid PID in lockfile - treat as stale
      warn("lockfile", "removing stale lockfile (invalid content)")
      removeLockfile()
    except IOError:
      # Can't read lockfile - treat as stale
      warn("lockfile", "removing stale lockfile (unreadable)")
      removeLockfile()

proc forceClearLockfile*() =
  ## Force clear the lockfile regardless of state (for manual unlock)
  if fileExists(lockfilePath):
    try:
      let content = readFile(lockfilePath).strip()
      if content != "":
        let pid = try: parseInt(content) except ValueError: 0
        if pid > 0:
          info("lockfile", "force clearing lockfile (was owned by PID " & $pid & ")")
        else:
          info("lockfile", "force clearing lockfile")
      else:
        info("lockfile", "force clearing lockfile (empty)")
    except IOError:
      info("lockfile", "force clearing lockfile")
    removeLockfile()
  else:
    info("lockfile", "no lockfile exists")

proc clearErrorCallback*() =
  ## Clear the error callback (call after successful operation)
  setErrorCallback(nil)
