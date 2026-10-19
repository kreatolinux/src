## Per-core state and runtime directories (§19.1, §20.3 step 5, §20.4 step 7).
##
## Both directories are mode 0700 and owned by the core's `account` (user
## mode: the daemon's user). The runtime directory is created fresh on load
## and removed on unload; the state directory is created only once
## filesystems are ready, never below a mount point that is not mounted yet,
## and is never removed by Jumpstart.
import std/[os, strutils]
import posix
import jumpstartcore/[errors, names]

type
  CoreDirOwner* = object
    uid*, gid*: int
  CoreDirectories* = object
    stateDir*, runtimeDir*: string

proc fail(code: CoreErrorCode; message, core: string) {.noreturn.} =
  raise newCoreError(code, message, core)

proc coreDirectories*(stateRoot, runtimeRoot, core: string): CoreDirectories =
  if not validCoreName(core, extension = false):
    fail(ecName, "invalid core name", core)
  if not stateRoot.isAbsolute or not runtimeRoot.isAbsolute:
    fail(ecIo, "per-core roots must be absolute", core)
  CoreDirectories(stateDir: stateRoot / core, runtimeDir: runtimeRoot / core)

proc isRealDir(path: string): bool =
  var st: Stat
  lstat(path.cstring, st) == 0 and S_ISDIR(st.st_mode)

proc pathExists(path: string): bool =
  var st: Stat
  lstat(path.cstring, st) == 0

proc makePrivateDir(path: string; owner: CoreDirOwner; core: string) =
  if posix.mkdir(path.cstring, Mode(0o700)) != 0:
    fail(ecIo, "cannot create " & path & ": " & osErrorMsg(osLastError()), core)
  # mkdir is subject to umask; set the exact mode, then the owner.
  if posix.chmod(path.cstring, Mode(0o700)) != 0:
    fail(ecIo, "cannot set mode of " & path & ": " & osErrorMsg(osLastError()), core)
  if owner.uid >= 0 and posix.lchown(path.cstring, Uid(owner.uid), Gid(owner.gid)) != 0:
    fail(ecIo, "cannot set owner of " & path & ": " & osErrorMsg(osLastError()), core)

# C macros (their values differ per OS and architecture), read as C expressions.
let
  ONoFollow {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint
  ODirectory {.importc: "O_DIRECTORY", header: "<fcntl.h>".}: cint
  AtRemoveDir {.importc: "AT_REMOVEDIR", header: "<fcntl.h>".}: cint
  AtSymlinkNoFollow {.importc: "AT_SYMLINK_NOFOLLOW", header: "<fcntl.h>".}: cint

proc c_openat(dirfd: cint; path: cstring; flags: cint): cint
  {.importc: "openat", header: "<fcntl.h>".}
proc c_unlinkat(dirfd: cint; path: cstring; flags: cint): cint
  {.importc: "unlinkat", header: "<unistd.h>".}
proc c_fstatat(dirfd: cint; path: cstring; st: var Stat; flags: cint): cint
  {.importc: "fstatat", header: "<sys/stat.h>".}
proc c_fdopendir(fd: cint): ptr DIR {.importc: "fdopendir", header: "<dirent.h>".}

proc lastError(what, path: string) {.noreturn.} =
  raise newException(OSError, what & " " & path & ": " & osErrorMsg(osLastError()))

proc entryNames(dirfd: cint; path: string): seq[string] =
  ## The names in an open directory, read through a duplicate descriptor.
  let copy = posix.dup(dirfd)
  if copy < 0: lastError("cannot duplicate descriptor of", path)
  let handle = c_fdopendir(copy)
  if handle.isNil:
    discard posix.close(copy)
    lastError("cannot list", path)
  defer: discard closedir(handle)
  while true:
    let entry = readdir(handle)
    if entry.isNil: break
    let name = $cast[cstring](addr entry.d_name[0])
    if name != "." and name != "..": result.add name

proc wipeDir(dirfd: cint; path: string; device: Dev) =
  ## Removes the contents of an open directory with descriptor-relative calls
  ## only: every step is `unlinkat`, `fstatat(AT_SYMLINK_NOFOLLOW)` or an
  ## `openat(O_NOFOLLOW)`, so a symbolic link swapped in at any moment is
  ## unlinked, never followed. It does not cross into another filesystem.
  for name in entryNames(dirfd, path):
    var st: Stat
    if c_fstatat(dirfd, name.cstring, st, AtSymlinkNoFollow) != 0:
      if errno == ENOENT: continue
      lastError("cannot stat", path / name)
    var isDir = S_ISDIR(st.st_mode)
    if isDir:
      let child = c_openat(dirfd, name.cstring, O_RDONLY or ONoFollow or ODirectory)
      if child < 0:
        # Replaced by a link or file after the stat: remove that, do not follow.
        if errno notin [ELOOP, ENOTDIR, ENOENT]: lastError("cannot open", path / name)
        isDir = false
      else:
        defer: discard posix.close(child)
        var inner: Stat
        if fstat(child, inner) != 0: lastError("cannot stat", path / name)
        if inner.st_dev != device:
          raise newException(OSError, "refusing to cross filesystems at " & path / name)
        wipeDir(child, path / name, device)
    if c_unlinkat(dirfd, name.cstring, if isDir: AtRemoveDir else: 0) != 0 and
        errno != ENOENT:
      lastError("cannot remove", path / name)

proc removeTree(path: string) =
  ## Never follows symbolic links, not even ones swapped in while it runs.
  var st: Stat
  if lstat(path.cstring, st) != 0:
    if errno == ENOENT: return
    lastError("cannot stat", path)
  if not S_ISDIR(st.st_mode):
    if posix.unlink(path.cstring) != 0 and errno != ENOENT: lastError("cannot remove", path)
    return
  let fd = posix.open(path.cstring, O_RDONLY or ONoFollow or ODirectory)
  if fd < 0:
    if errno == ENOENT: return
    lastError("cannot open", path)
  try:
    var inner: Stat
    if fstat(fd, inner) != 0: lastError("cannot stat", path)
    wipeDir(fd, path, inner.st_dev)
  finally: discard posix.close(fd)
  if posix.rmdir(path.cstring) != 0 and errno != ENOENT: lastError("cannot remove", path)

proc ensureDaemonDir*(path: string; private = false; warn: proc(message: string) = nil) =
  ## Daemon directory setup (§7.4, §8.3). A missing directory is created
  ## (failure raises). An existing one is only made private when its mode is
  ## not already `0700`: a read-only root (EROFS) or a refused chmod (EPERM)
  ## cannot be fixed here, so it is reported through `warn` and left to the
  ## checks that use the directory, which still reject one that is not
  ## private or not correctly owned.
  if not dirExists(path):
    createDir(path)
    if private: setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})
    return
  if not private: return
  var st: Stat
  if stat(path.cstring, st) == 0 and (st.st_mode and Mode(0o7777)) == Mode(0o700): return
  try: setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})
  except OSError as e:
    if e.errorCode in [EROFS, EPERM]:
      if not warn.isNil:
        warn("cannot make " & path & " private (" & osErrorMsg(OSErrorCode(e.errorCode)) &
          "); using it as it is")
    else: raise

proc createRuntimeDir*(dirs: CoreDirectories; owner: CoreDirOwner; core: string) =
  ## Load step 5: a fresh runtime directory. Leftovers of an earlier load are
  ## removed first, since nothing from an earlier load is reused (§20.3 step 2).
  let parent = parentDir(dirs.runtimeDir)
  if not isRealDir(parent):
    fail(ecIo, "runtime root is unavailable: " & parent, core)
  try: removeTree(dirs.runtimeDir)
  except CatchableError as e:
    fail(ecIo, "cannot clear stale runtime directory: " & e.msg, core)
  makePrivateDir(dirs.runtimeDir, owner, core)

proc removeRuntimeDir*(dirs: CoreDirectories; core: string) =
  ## Unload step 7 and load rollback.
  try: removeTree(dirs.runtimeDir)
  except CatchableError as e:
    fail(ecIo, "cannot remove runtime directory: " & e.msg, core)

proc decodeField(field: string): string =
  var i = 0
  while i < field.len:
    if field[i] == '\\' and i + 3 < field.len and
        field[i+1] in {'0'..'7'} and field[i+2] in {'0'..'7'} and field[i+3] in {'0'..'7'}:
      result.add char((ord(field[i+1]) - 48) * 64 + (ord(field[i+2]) - 48) * 8 +
                      ord(field[i+3]) - 48)
      i += 4
    else:
      result.add field[i]
      inc i

proc pendingFstabMounts*(fstab, mountInfo: string): seq[string] =
  ## Mount points listed in /etc/fstab that are not mounted yet. Nothing may
  ## be created below them, because the later mount would shadow it.
  var mounted: seq[string]
  for line in mountInfo.splitLines:
    let fields = line.splitWhitespace
    if fields.len >= 5: mounted.add decodeField(fields[4])
  for raw in fstab.splitLines:
    let line = raw.strip
    if line.len == 0 or line[0] == '#': continue
    let fields = line.splitWhitespace
    if fields.len < 3: continue
    let target = decodeField(fields[1])
    if not target.isAbsolute or fields[2] == "swap": continue
    let options = if fields.len >= 4: fields[3].split(',') else: @[]
    if "noauto" in options: continue
    let clean = normalizedPath(target)
    if clean notin mounted and clean notin result: result.add clean

proc belowPendingMount*(path: string; pending: openArray[string]): string =
  ## The first pending mount point at or above path, or "".
  let clean = normalizedPath(path)
  for mount in pending:
    if mount == "/": continue
    if clean == mount or clean.startsWith(mount & "/"): return mount

proc ensureStateDir*(dirs: CoreDirectories; owner: CoreDirOwner; core: string;
                     filesystemsReady: bool;
                     pendingMounts: openArray[string] = []): bool =
  ## Load step 5 and its retries (when filesystems become ready and before
  ## each dispatch). Returns true when the state directory exists. Raises
  ## CoreError(E_IO) on failure, which the caller logs without failing the
  ## load. Missing parents (/var/lib/jumpstart/cores) are created as root-owned
  ## 0755 directories, but only below mounted filesystems.
  if isRealDir(dirs.stateDir): return true
  if not filesystemsReady: return false
  let shadow = belowPendingMount(dirs.stateDir, pendingMounts)
  if shadow.len > 0:
    fail(ecIo, "state directory is below " & shadow & ", which is not mounted yet", core)
  if pathExists(dirs.stateDir):
    fail(ecIo, "state path exists and is not a directory: " & dirs.stateDir, core)
  let parent = parentDir(dirs.stateDir)
  try:
    if not isRealDir(parent): createDir(parent)
  except CatchableError as e:
    fail(ecIo, "cannot create state root " & parent & ": " & e.msg, core)
  makePrivateDir(dirs.stateDir, owner, core)
  true
