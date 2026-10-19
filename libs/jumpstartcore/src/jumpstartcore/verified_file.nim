## Verified reads of core files (jumpstart-cores §8.3, §24).
##
## Ownership can change between discovery and use, so a manifest is opened
## with `O_NOFOLLOW` (the core directory too) and re-checked with `fstat` on
## the open descriptor: regular file, owned by the trusted owner or root, not
## writable by group or other. Failure is `E_PERMISSION`. The descriptor is
## read to the end, so the bytes parsed are the bytes that were verified.
import std/[os, posix]
import ./errors

proc verifiedFail(text: string; err = OSErrorCode(0)) {.noreturn.} =
  let detail = if err.int != 0: ": " & osErrorMsg(err) else: ""
  raise newCoreError(ecPermission, text & detail)

var oDirectory {.importc: "O_DIRECTORY", header: "<fcntl.h>".}: cint
var oNoFollow {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint

proc openatFd(dirFd: cint; name: cstring; flags: cint): cint
  {.importc: "openat", header: "<fcntl.h>", varargs.}

proc readVerifiedFile*(path: string; trustedUid: Uid): string =
  ## Contents of `path`, which must be an absolute path whose final component
  ## and containing directory are not symbolic links.
  if path.len == 0 or not path.isAbsolute or '\0' in path:
    verifiedFail("file path must be absolute: " & path)
  let (dir, name) = splitPath(path)
  if name.len == 0 or name in [".", ".."]:
    verifiedFail("invalid file path: " & path)
  let dirFd = posix.open((if dir.len == 0: "/" else: dir).cstring,
    O_RDONLY or oDirectory or oNoFollow or O_CLOEXEC)
  if dirFd < 0: verifiedFail("cannot open directory " & dir, osLastError())
  let fd = openatFd(dirFd, name.cstring, O_RDONLY or oNoFollow or O_CLOEXEC)
  let openError = osLastError()
  discard posix.close(dirFd)
  if fd < 0: verifiedFail("cannot open " & path, openError)
  try:
    var st: Stat
    if fstat(fd, st) != 0: verifiedFail("cannot fstat " & path, osLastError())
    if not S_ISREG(st.st_mode): verifiedFail("not a regular file: " & path)
    if st.st_uid != trustedUid and st.st_uid != Uid(0):
      verifiedFail("not owned by the trusted owner: " & path)
    if (int(st.st_mode) and 0o022) != 0:
      verifiedFail("writable by group or other: " & path)
    var chunk = newString(65536)
    while true:
      let count = posix.read(fd, addr chunk[0], chunk.len)
      if count > 0: result.add chunk[0 ..< count]
      elif count == 0: break
      elif osLastError() != OSErrorCode(EINTR):
        raise newCoreError(ecIo, "cannot read " & path & ": " & osErrorMsg(osLastError()))
  finally:
    discard posix.close(fd)
