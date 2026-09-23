import os
import strutils
import posix
import locks
import ../../common/logging
import transactions/main
import sqlite
import transactions/barrier
export sqlite.lockfilePath


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

var noFollow {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint

proc flock(fd: cint, operation: cint): cint {.importc, header: "<sys/file.h>".}
var packageLockFd: cint = -1
var packageLockDepth = 0
var localLockDepth {.threadvar.}: int
var packageLockMutex: Lock
initLock(packageLockMutex)

proc removeLockfile*() =
  ## Release only this thread's lease. Other nested/worker leases stay held.
  acquire(packageLockMutex)
  defer: release(packageLockMutex)
  if localLockDepth == 0:
    return
  if localLockDepth == 1:
    closeDb() # Connections opened under exclusivity must not outlive it.
    setMutationLockOwned(false)
  dec localLockDepth
  dec packageLockDepth
  if packageLockDepth == 0:
    try:
      releaseHistoryOwnership()
      if fileExists(lockfilePath):
        removeFile(lockfilePath)
    finally:
      setMutationLockOwned(false)
      discard flock(packageLockFd, 8) # LOCK_UN
      discard posix.close(packageLockFd)
      packageLockFd = -1

proc createLockfile*() =
  ## Process-wide mutation lease. Parallel install workers deliberately share
  ## ownership; only the first lease runs recovery, before admitting workers.
  acquire(packageLockMutex)
  defer: release(packageLockMutex)
  if packageLockDepth > 0:
    setMutationLockOwned(true)
    inc packageLockDepth
    inc localLockDepth
    return
  closeDb() # Drop this thread's read lease before requesting exclusivity.
  let fd = posix.open((lockfilePath & ".guard").cstring,
      O_CREAT or O_RDWR or O_CLOEXEC or noFollow, Mode(0o644))
  if fd < 0: raiseOSError(osLastError(), "cannot open package lock")
  if flock(fd, 2 or 4) != 0: # LOCK_EX | LOCK_NB
    discard posix.close(fd)
    raise newException(IOError, "another package mutation holds the lock")
  setMutationLockOwned(true)
  try:
    if fchmod(fd, Mode(0o644)) != 0:
      raiseOSError(osLastError(), "cannot set package guard permissions")
    writeFile(lockfilePath, $getCurrentPid())
    closeDb()
    discard recoverFromCrash()
  except:
    # Keep exclusion until recovery has unwound, even when logging errors.
    try:
      closeDb()
      if fileExists(lockfilePath): removeFile(lockfilePath)
    finally:
      setMutationLockOwned(false)
      discard flock(fd, 8)
      discard posix.close(fd)
    raise
  packageLockFd = fd
  packageLockDepth = 1
  localLockDepth = 1

proc checkLockfile*() =
  ## Check if lockfile exists. Auto-removes stale locks from dead processes.
  if localLockDepth > 0:
    return
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
          removeFile(lockfilePath)
      else:
        # Empty lockfile (old format) - treat as stale
        warn("lockfile", "removing stale lockfile (empty, old format)")
        removeFile(lockfilePath)
    except ValueError:
      # Invalid PID in lockfile - treat as stale
      warn("lockfile", "removing stale lockfile (invalid content)")
      removeFile(lockfilePath)
    except IOError:
      # Can't read lockfile - treat as stale
      warn("lockfile", "removing stale lockfile (unreadable)")
      removeFile(lockfilePath)

proc forceClearLockfile*() =
  ## Clear only an unowned PID marker. Never bypass the kernel mutation lock.
  acquire(packageLockMutex)
  defer: release(packageLockMutex)
  if packageLockDepth > 0:
    raise newException(IOError, "cannot clear an active package lock")
  let fd = posix.open((lockfilePath & ".guard").cstring,
      O_CREAT or O_RDWR or O_CLOEXEC or noFollow, Mode(0o644))
  if fd < 0: raiseOSError(osLastError(), "cannot open package lock")
  defer: discard posix.close(fd)
  if flock(fd, 2 or 4) != 0:
    raise newException(IOError, "cannot clear another process's package lock")
  defer: discard flock(fd, 8)
  if fileExists(lockfilePath):
    removeFile(lockfilePath)
    info("lockfile", "cleared stale lockfile")
  else:
    info("lockfile", "no lockfile exists")

proc clearErrorCallback*() =
  ## Kept for callers of the old API. Logging must never release mutation
  ## ownership before exception rollback and cleanup finish.
  discard

template withLockfile*(body: untyped) =
  createLockfile()
  try:
    body
  finally:
    removeLockfile()
