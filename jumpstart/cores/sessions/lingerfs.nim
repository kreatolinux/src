## Linger marker storage (§7.6 step 6, §21.8).
##
## A user lingers when the root-owned empty file
## `/etc/jumpstart/users/linger/USERNAME` exists. Anything else in that
## directory (symlinks, non-empty files, files not owned by root, directories)
## is ignored and reported. The directory itself must be a root-owned real
## directory that is not writable by group or other; otherwise no marker is
## trusted. Markers are created and removed atomically.
import std/[os, strutils]
import posix
import ./session_manager

type
  LingerLog* = proc(message: string) {.closure.}

const DefaultLingerRoot* = "/etc/jumpstart/users/linger"

var oNoFollow {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint
proc cRename(source, target: cstring): cint {.importc: "rename", header: "<stdio.h>".}

proc validLingerName*(name: string): bool =
  ## Password-database user names as accepted by shadow-utils, minus `root`.
  if name.len == 0 or name.len > 32 or name == "root": return false
  if name[0] notin {'a'..'z', 'A'..'Z', '_'}: return false
  for i, c in name:
    if c in {'a'..'z', 'A'..'Z', '0'..'9', '_', '-', '.'}: continue
    if c == '$' and i == name.high: continue
    return false
  true

proc report(log: LingerLog; message: string) =
  if not log.isNil:
    try: log(message)
    except CatchableError: discard

proc trustedDirectory(root: string; ownerUid: int; log: LingerLog): bool =
  var st: Stat
  if lstat(root.cstring, st) != 0: return false
  if not S_ISDIR(st.st_mode) or st.st_uid != Uid(ownerUid) or
      (st.st_mode and Mode(0o022)) != 0:
    log.report("linger directory " & root & " is not a root-owned, non-writable directory; ignoring markers")
    return false
  true

proc markerValid*(path: string; ownerUid = 0): bool =
  ## A marker is a regular, empty file owned by root (not a symlink).
  var st: Stat
  lstat(path.cstring, st) == 0 and S_ISREG(st.st_mode) and
    st.st_uid == Uid(ownerUid) and st.st_size == 0

proc listLingerNames*(root: string; ownerUid = 0; log: LingerLog = nil): seq[string] =
  if not trustedDirectory(root, ownerUid, log): return
  for kind, path in walkDir(root):
    let name = lastPathPart(path)
    if name.startsWith("."): continue # in-progress atomic creations
    if not validLingerName(name):
      log.report("ignoring linger entry with an invalid user name: " & name)
      continue
    if not markerValid(path, ownerUid):
      log.report("ignoring linger marker that is not a root-owned empty file: " & name)
      continue
    result.add name

proc ensureLingerDirectory(root: string; ownerUid: int) =
  var st: Stat
  if lstat(root.cstring, st) != 0:
    let parent = parentDir(root)
    if not dirExists(parent): createDir(parent)
    if posix.mkdir(root.cstring, Mode(0o755)) != 0 and osLastError() != OSErrorCode(EEXIST):
      raiseOSError(osLastError(), root)
    if posix.chmod(root.cstring, Mode(0o755)) != 0: raiseOSError(osLastError(), root)
    if lstat(root.cstring, st) != 0: raiseOSError(osLastError(), root)
  if not S_ISDIR(st.st_mode) or st.st_uid != Uid(ownerUid) or
      (st.st_mode and Mode(0o022)) != 0:
    raise newException(IOError, "linger directory is not a root-owned, non-writable directory: " & root)

proc syncDirectory(path: string) =
  let fd = posix.open(path.cstring, O_RDONLY or O_CLOEXEC)
  if fd >= 0:
    discard fsync(fd)
    discard posix.close(fd)

proc createLingerMarker*(root, name: string; ownerUid = 0) =
  ## Atomically create the marker: an empty file written under a temporary
  ## name, fsynced, then renamed into place.
  if not validLingerName(name): raise newException(ValueError, "invalid linger user name: " & name)
  ensureLingerDirectory(root, ownerUid)
  let target = root / name
  if markerValid(target, ownerUid): return
  let temp = root / ("." & name & ".tmp." & $getpid())
  discard posix.unlink(temp.cstring)
  let fd = posix.open(temp.cstring, O_WRONLY or O_CREAT or O_EXCL or O_CLOEXEC or oNoFollow,
                      Mode(0o644))
  if fd < 0: raiseOSError(osLastError(), temp)
  var ok, closed = false
  try:
    if fsync(fd) != 0: raiseOSError(osLastError(), temp)
    closed = true
    if posix.close(fd) != 0: raiseOSError(osLastError(), temp)
    if cRename(temp.cstring, target.cstring) != 0: raiseOSError(osLastError(), target)
    ok = true
  finally:
    if not closed: discard posix.close(fd)
    if not ok: discard posix.unlink(temp.cstring)
  syncDirectory(root)

proc removeLingerMarker*(root, name: string) =
  ## unlink(2) is atomic; an absent marker is not an error.
  if not validLingerName(name): raise newException(ValueError, "invalid linger user name: " & name)
  let target = root / name
  if posix.unlink(target.cstring) != 0 and osLastError() != OSErrorCode(ENOENT):
    raiseOSError(osLastError(), target)
  syncDirectory(root)

proc lingerFs*(root = DefaultLingerRoot; ownerUid = 0; log: LingerLog = nil): LingerFs =
  ## Production LingerFs for session_manager. `ownerUid` is 0 in production
  ## and injectable only so unprivileged tests can exercise the validation.
  LingerFs(
    listNames: proc(): seq[string] = listLingerNames(root, ownerUid, log),
    createMarker: proc(name: string) = createLingerMarker(root, name, ownerUid),
    removeMarker: proc(name: string) = removeLingerMarker(root, name))
