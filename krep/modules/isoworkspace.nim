## Private ISO build workspaces and atomic output publication.
## No mount points or loop devices are created here. Callers must not mount
## anything inside a workspace: cleanup only removes ordinary filesystem trees.
import std/[os, tempfiles]
import posix

when not defined(posix):
  {.error: "ISO workspaces require POSIX filesystem operations".}

proc openAt(fd: cint, path: cstring, flags: cint): cint
    {.importc: "openat", header: "<fcntl.h>".}
proc unlinkAt(fd: cint, path: cstring, flags: cint): cint
    {.importc: "unlinkat", header: "<unistd.h>".}
proc fdOpenDir(fd: cint): ptr DIR {.importc: "fdopendir", header: "<dirent.h>".}
proc renamePath(source, destination: cstring): cint
    {.importc: "rename", header: "<stdio.h>".}
var removeDirectoryFlag {.importc: "AT_REMOVEDIR", header: "<fcntl.h>".}: cint
when not declared(O_DIRECTORY):
  var O_DIRECTORY {.importc, header: "<fcntl.h>".}: cint
when not declared(O_NOFOLLOW):
  var O_NOFOLLOW {.importc, header: "<fcntl.h>".}: cint
when not declared(O_CLOEXEC):
  var O_CLOEXEC {.importc, header: "<fcntl.h>".}: cint

type
  IsoWorkspace* = ref object
    directory: string
    fd: cint
    active: bool
  OutputLock* = ref object
    destination: string
    directory: string
    fd: cint
    active: bool

proc path*(workspace: IsoWorkspace): string = workspace.directory
proc outputPath*(lock: OutputLock): string = lock.destination
proc lockPath*(lock: OutputLock): string = lock.directory

proc openDirectory(path: string): cint =
  result = posix.open(path.cstring, O_RDONLY or O_DIRECTORY or O_NOFOLLOW or O_CLOEXEC)
  if result < 0: raiseOSError(osLastError(), path)

proc ownsDirectory(path: string, fd: cint): bool =
  var held, current: Stat
  result = fd >= 0 and fstat(fd, held) == 0 and
    lstat(path.cstring, current) == 0 and S_ISDIR(current.st_mode) and
    held.st_dev == current.st_dev and held.st_ino == current.st_ino

proc removeContents(fd: cint) =
  ## Walk by directory descriptors, never by a symlink-resolved child path.
  let scanFd = dup(fd)
  if scanFd < 0: raiseOSError(osLastError())
  let stream = fdOpenDir(scanFd)
  if stream == nil:
    let error = osLastError()
    discard posix.close(scanFd)
    raiseOSError(error)
  defer: discard closedir(stream)
  while true:
    errno = 0
    let entry = readdir(stream)
    if entry == nil:
      if errno != 0: raiseOSError(osLastError())
      break
    let name = $cast[cstring](addr entry.d_name[0])
    if name == "." or name == "..": continue
    let child = openAt(fd, name.cstring, O_RDONLY or O_DIRECTORY or
        O_NOFOLLOW or O_CLOEXEC)
    if child >= 0:
      try:
        removeContents(child)
      finally:
        discard posix.close(child)
      if unlinkAt(fd, name.cstring, removeDirectoryFlag) != 0 and errno != ENOENT:
        raiseOSError(osLastError(), name)
    else:
      let error = osLastError()
      if error == OSErrorCode(ENOENT): continue
      if error != OSErrorCode(ENOTDIR) and error != OSErrorCode(ELOOP):
        raiseOSError(error, name)
      if unlinkAt(fd, name.cstring, 0) != 0 and errno != ENOENT:
        raiseOSError(osLastError(), name)

proc createWorkspace*(parentDir = ""): IsoWorkspace =
  ## parentDir must already exist. An empty parent uses the system temp dir.
  # std/tempfiles supplies unique names, but createTempDir uses default mkdir
  # permissions. Create atomically with 0700 instead of briefly exposing 0777
  # under a permissive umask before chmod.
  let parent = if parentDir.len == 0: getTempDir() else: parentDir
  var directory: string
  for attempt in 0 ..< 10000:
    let candidate = absolutePath(genTempPath("krep-iso-", "", parent))
    if mkdir(candidate.cstring, Mode(0o700)) == 0:
      directory = candidate
      break
    if errno != EEXIST: raiseOSError(osLastError(), candidate)
  if directory.len == 0:
    raise newException(IOError, "Cannot create a unique ISO workspace")
  var fd = -1.cint
  try:
    fd = openDirectory(directory)
    if fchmod(fd, Mode(0o700)) != 0: raiseOSError(osLastError(), directory)
    result = IsoWorkspace(directory: directory, fd: fd, active: true)
  except:
    if fd >= 0: discard posix.close(fd)
    discard rmdir(directory.cstring)
    raise

proc cleanupWorkspace*(workspace: IsoWorkspace) =
  ## Idempotent. A replacement at the original path is never removed.
  if workspace == nil or not workspace.active: return
  try:
    if not ownsDirectory(workspace.directory, workspace.fd):
      raise newException(IOError, "Workspace path no longer belongs to this build: " &
          workspace.directory)
    removeContents(workspace.fd)
    if not ownsDirectory(workspace.directory, workspace.fd):
      raise newException(IOError, "Workspace was replaced during cleanup: " &
          workspace.directory)
    if rmdir(workspace.directory.cstring) != 0:
      raiseOSError(osLastError(), workspace.directory)
  finally:
    workspace.active = false
    discard posix.close(workspace.fd)
    workspace.fd = -1

proc withWorkspace*(action: proc(workspace: IsoWorkspace) {.closure.},
    parentDir = "") =
  let workspace = createWorkspace(parentDir)
  try:
    action(workspace)
  finally:
    cleanupWorkspace(workspace)

proc acquireOutputLock*(outputPath: string): OutputLock =
  ## Existing locks are never reclaimed, even if they appear stale. The caller
  ## must release its handle in a finally block. Output parent must exist.
  if outputPath.len == 0:
    raise newException(ValueError, "Output path must not be empty")
  let destination = normalizedPath(absolutePath(outputPath))
  let directory = destination & ".lock"
  if mkdir(directory.cstring, Mode(0o700)) != 0:
    raiseOSError(osLastError(), "Cannot acquire output lock: " & directory)
  var fd = -1.cint
  try:
    fd = openDirectory(directory)
    if fchmod(fd, Mode(0o700)) != 0: raiseOSError(osLastError(), directory)
    result = OutputLock(destination: destination, directory: directory,
                        fd: fd, active: true)
  except:
    if fd >= 0: discard posix.close(fd)
    discard rmdir(directory.cstring)
    raise

proc releaseOutputLock*(lock: OutputLock) =
  ## Remove only the exact, empty directory created by this handle.
  if lock == nil or not lock.active: return
  try:
    if not ownsDirectory(lock.directory, lock.fd):
      raise newException(IOError, "Output lock no longer belongs to this build: " &
          lock.directory)
    if rmdir(lock.directory.cstring) != 0:
      raiseOSError(osLastError(), lock.directory)
  finally:
    lock.active = false
    discard posix.close(lock.fd)
    lock.fd = -1

proc publishIso*(stagedPath: string, lock: OutputLock, overwrite = false,
                 checkCancelled: proc() {.closure.} = nil) =
  ## Copy into the destination filesystem before publishing. By default link()
  ## atomically refuses any existing destination, including dangling symlinks.
  ## Explicit overwrite uses atomic rename(), never a cross-device move.
  if lock == nil or not lock.active or not ownsDirectory(lock.directory, lock.fd):
    raise newException(IOError, "Publishing requires an owned output lock")
  let (temporary, temporaryPath) = createTempFile(".krep-iso-", ".partial",
                                               parentDir(lock.destination))
  var temporaryOpen = true
  try:
    var source = open(stagedPath, fmRead)
    try:
      var buffer: array[64 * 1024, char]
      while true:
        if checkCancelled != nil: checkCancelled()
        let count = source.readBuffer(addr buffer[0], buffer.len)
        if count == 0: break
        if temporary.writeBuffer(addr buffer[0], count) != count:
          raise newException(IOError, "Failed to write staged ISO")
    finally:
      source.close()
    temporary.flushFile()
    if fsync(cint(temporary.getFileHandle())) != 0:
      raiseOSError(osLastError(), temporaryPath)
    temporary.close()
    temporaryOpen = false
    if not ownsDirectory(lock.directory, lock.fd):
      raise newException(IOError, "Output lock was replaced during publication")
    if checkCancelled != nil: checkCancelled()
    if overwrite:
      if renamePath(temporaryPath.cstring, lock.destination.cstring) != 0:
        raiseOSError(osLastError(), lock.destination)
    elif posix.link(temporaryPath.cstring, lock.destination.cstring) != 0:
      raiseOSError(osLastError(), lock.destination)
  finally:
    if temporaryOpen: temporary.close()
    removeFile(temporaryPath)
