## Persistent enabled-core marker storage.
import std/[algorithm, os, posix, sets, strutils, tables]
import ../manifest/discovery
import jumpstartcore/[errors, names]
export errors

when not declared(O_DIRECTORY):
  var O_DIRECTORY {.importc, header: "<fcntl.h>".}: cint
when not declared(O_NOFOLLOW):
  var O_NOFOLLOW {.importc, header: "<fcntl.h>".}: cint
when not declared(O_CLOEXEC):
  var O_CLOEXEC {.importc, header: "<fcntl.h>".}: cint
proc flock(fd: cint; operation: cint): cint {.importc, header: "<sys/file.h>".}
proc renamePath(oldPath, newPath: cstring): cint {.importc: "rename", header: "<stdio.h>".}

type
  EnabledState* = object
    initialized*: bool
    enabled*: seq[string]
  StatePaths* = object
    enabledDir*: string
    lockFile*: string
    trustedUid*: Uid
  StateInvariant* = proc(enabled: seq[string]) {.closure.}
  StateError* = object of CoreError
    ## `code` is E_STATE, E_PERMISSION, E_NAME, E_NOT_FOUND, E_DELEGATION, or
    ## the rejection code of an invalid core; `message` has no code prefix.
  DelegationMap* = Table[string, seq[string]]
    ## Discovered, valid core -> the cores its delegate backends target.
  TransitionCheck = proc(old, wanted: seq[string]) {.closure.}

const
  MarkerTempPrefix = ".marker-"
  StateTempPrefix = ".enabled-"
  ## Parents created on first use. §8.3 only forbids group/other write; the
  ## process umask may clear further bits.
  CreatedParentMode = Mode(0o755)

proc stateFail(code: CoreErrorCode; text: string; core = "") {.noreturn.} =
  var e = newException(StateError, text)
  e.code = code; e.message = text; e.core = core
  raise e

proc stateFail(text: string) {.noreturn.} = stateFail(ecState, text)

proc lst(path: string): Stat =
  if lstat(path.cstring, result) != 0: raiseOSError(osLastError(), path)

proc isTemporaryName(name, prefix: string): bool =
  ## The implementation's own temporary names: PREFIX PID "-" N.
  if not name.startsWith(prefix): return false
  let parts = name[prefix.len .. ^1].split('-')
  parts.len == 2 and parts[0].len > 0 and parts[1].len > 0 and
    parts[0].allCharsInSet(Digits) and parts[1].allCharsInSet(Digits)

proc validateOwned(st: Stat; path: string; uid: Uid) =
  if st.st_uid != Uid(0) and st.st_uid != uid:
    stateFail(ecPermission, "untrusted owner: " & path)
  if (st.st_mode and Mode(0o022)) != 0:
    stateFail(ecPermission, "group/other writable: " & path)

proc validateDirectory(st: Stat; path: string; uid: Uid) =
  if S_ISLNK(st.st_mode) or not S_ISDIR(st.st_mode):
    stateFail(ecPermission, "state parent is not a directory: " & path)
  validateOwned(st, path, uid)

proc validateDirectory(path: string; uid: Uid) =
  validateDirectory(lst(path), path, uid)

proc checkTrustedDirectory*(path: string; trustedUid: Uid; required = false) =
  ## §8.3 ownership rule for directories outside the core roots, such as the
  ## system-mode `/var/lib/jumpstart/cores` and `/run/jumpstart/cores`: a real
  ## directory owned by `trustedUid` or root and not group/other writable.
  ## An absent directory passes unless `required`.
  var st: Stat
  if lstat(path.cstring, st) != 0:
    if errno == ENOENT and not required: return
    raiseOSError(osLastError(), path)
  if S_ISLNK(st.st_mode) or not S_ISDIR(st.st_mode):
    stateFail(ecPermission, "not a directory: " & path)
  validateOwned(st, path, trustedUid)

proc readEnabledState*(paths: StatePaths): EnabledState =
  ## Returns the compatibility default without creating anything when the
  ## enabled directory, or any of its parents, is absent (§9.2).
  let uninitialized = EnabledState(initialized: false, enabled: @["serviceHandler"])
  let parent = parentDir(paths.enabledDir)
  var pst: Stat
  if lstat(parent.cstring, pst) != 0:
    if errno == ENOENT: return uninitialized
    raiseOSError(osLastError(), parent)
  validateDirectory(pst, parent, paths.trustedUid)
  var dst: Stat
  if lstat(paths.enabledDir.cstring, dst) != 0:
    if errno == ENOENT: return uninitialized
    raiseOSError(osLastError(), paths.enabledDir)
  if S_ISLNK(dst.st_mode) or not S_ISDIR(dst.st_mode):
    stateFail("enabled path is not a directory")
  validateOwned(dst, paths.enabledDir, paths.trustedUid)
  for kind, path in walkDir(paths.enabledDir, relative = false, checkDir = true):
    let name = extractFilename(path)
    var st: Stat
    if lstat(path.cstring, st) != 0:
      # Readers do not take the lock; an entry renamed or unlinked by a
      # concurrent writer since readdir was an atomic per-marker change.
      if errno == ENOENT: continue
      raiseOSError(osLastError(), path)
    if isTemporaryName(name, MarkerTempPrefix):
      # An enable interrupted before its rename leaves only its own empty
      # temporary file. It never became a marker, so the old state stands.
      if S_ISLNK(st.st_mode) or not S_ISREG(st.st_mode) or st.st_size != 0:
        stateFail("invalid temporary marker: " & name)
      validateOwned(st, path, paths.trustedUid)
      continue
    if name != "serviceHandler" and not validCoreName(name):
      stateFail("invalid marker name: " & name)
    if S_ISLNK(st.st_mode) or not S_ISREG(st.st_mode):
      stateFail("marker is not a regular file: " & name)
    validateOwned(st, path, paths.trustedUid)
    if st.st_size != 0: stateFail("non-empty marker: " & name)
    result.enabled.add(name)
  result.enabled.sort(system.cmp[string])
  if result.enabled.len == 0: stateFail("enabled directory is empty")
  result.initialized = true

proc openDir(path: string): cint =
  result = posix.open(path.cstring, O_RDONLY or O_DIRECTORY or O_NOFOLLOW or O_CLOEXEC)
  if result < 0: raiseOSError(osLastError(), path)

proc syncDir(path: string) =
  let fd = openDir(path)
  try:
    if fsync(fd) != 0: raiseOSError(osLastError(), path)
  finally: discard posix.close(fd)

proc createMarker(directory, finalName: string) =
  let finalPath = directory / finalName
  if fileExists(finalPath): return
  var tempPath: string
  var fd = -1.cint
  for n in 0 ..< 1000:
    tempPath = directory / (MarkerTempPrefix & $getpid() & "-" & $n)
    fd = posix.open(tempPath.cstring, O_WRONLY or O_CREAT or O_EXCL or
      O_CLOEXEC or O_NOFOLLOW, Mode(0o600))
    if fd >= 0: break
    if errno != EEXIST: raiseOSError(osLastError(), tempPath)
  if fd < 0: raise newException(IOError, "cannot allocate temporary marker")
  try:
    try:
      if fchmod(fd, Mode(0o600)) != 0 or fsync(fd) != 0:
        raiseOSError(osLastError(), tempPath)
    finally: discard posix.close(fd)
    if renamePath(tempPath.cstring, finalPath.cstring) != 0:
      raiseOSError(osLastError(), finalPath)
  except CatchableError:
    discard unlink(tempPath.cstring)
    raise
  syncDir(directory)

proc removeTemporaryDir(path: string) =
  ## Removes an abandoned materialization directory. Only the regular files
  ## this module writes are unlinked; anything else leaves it in place.
  for kind, child in walkDir(path, relative = false):
    var st: Stat
    if lstat(child.cstring, st) != 0 or S_ISLNK(st.st_mode) or not S_ISREG(st.st_mode):
      return
    discard unlink(child.cstring)
  discard rmdir(path.cstring)

proc cleanTemporaries(paths: StatePaths) =
  ## Called with the lock held, when no other writer can own a temporary, so
  ## every temporary left behind belongs to an interrupted writer.
  var st: Stat
  if lstat(paths.enabledDir.cstring, st) == 0 and S_ISDIR(st.st_mode):
    for kind, path in walkDir(paths.enabledDir, relative = false):
      if isTemporaryName(extractFilename(path), MarkerTempPrefix) and
          lstat(path.cstring, st) == 0 and S_ISREG(st.st_mode):
        discard unlink(path.cstring)
  for kind, path in walkDir(parentDir(paths.enabledDir), relative = false):
    if isTemporaryName(extractFilename(path), StateTempPrefix) and
        lstat(path.cstring, st) == 0 and S_ISDIR(st.st_mode):
      removeTemporaryDir(path)

proc materialize(paths: StatePaths; names: seq[string]) =
  let parent = parentDir(paths.enabledDir)
  var temporary: string
  for n in 0 ..< 1000:
    temporary = parent / (StateTempPrefix & $getpid() & "-" & $n)
    if mkdir(temporary.cstring, Mode(0o700)) == 0: break
    if errno != EEXIST: raiseOSError(osLastError(), temporary)
    temporary.setLen(0)
  if temporary.len == 0: raise newException(IOError, "cannot allocate state directory")
  try:
    for name in names: createMarker(temporary, name)
    syncDir(temporary)
    if renamePath(temporary.cstring, paths.enabledDir.cstring) != 0:
      raiseOSError(osLastError(), paths.enabledDir)
    temporary.setLen(0)
    syncDir(parent)
  finally:
    if temporary.len != 0 and dirExists(temporary): removeTemporaryDir(temporary)

proc ensureDirectory(path: string) =
  ## Creates `path` and missing ancestors so the first change works on a
  ## system where the daemon never ran (§9.2). Existing entries are validated
  ## by the caller, not here.
  var st: Stat
  if lstat(path.cstring, st) == 0: return
  if errno != ENOENT: raiseOSError(osLastError(), path)
  let parent = parentDir(path)
  if parent.len > 0 and parent != path: ensureDirectory(parent)
  if mkdir(path.cstring, CreatedParentMode) != 0 and errno != EEXIST:
    raiseOSError(osLastError(), path)

proc withStateLock(paths: StatePaths; body: proc() {.closure.}) =
  let parent = parentDir(paths.lockFile)
  validateDirectory(parent, paths.trustedUid)
  let fd = posix.open(paths.lockFile.cstring, O_RDWR or O_CREAT or O_CLOEXEC or
    O_NOFOLLOW, Mode(0o600))
  if fd < 0: raiseOSError(osLastError(), paths.lockFile)
  try:
    var st: Stat
    if fstat(fd, st) != 0: raiseOSError(osLastError(), paths.lockFile)
    if not S_ISREG(st.st_mode): stateFail(ecPermission, "lock is not a regular file")
    validateOwned(st, paths.lockFile, paths.trustedUid)
    if fchmod(fd, Mode(0o600)) != 0: raiseOSError(osLastError(), paths.lockFile)
    if flock(fd, 2) != 0: raiseOSError(osLastError(), paths.lockFile) # LOCK_EX
    try: body()
    finally: discard flock(fd, 8) # LOCK_UN
  finally: discard posix.close(fd)

proc validateName(name: string) =
  if name != "serviceHandler" and not validCoreName(name):
    stateFail(ecName, "invalid or reserved core name: " & name, name)

proc planChange(old: EnabledState; name: string; enabling: bool;
                check: TransitionCheck; names: var seq[string]): bool =
  ## The decision half of a change, shared by the real write and the dry run:
  ## false when the effective set already is as wanted, otherwise `names` is
  ## the new sorted set. Raises E_STATE for an empty set and whatever `check`
  ## raises (E_DELEGATION), before anything is written.
  if (name in old.enabled) == enabling: return false
  var wanted = old.enabled.toHashSet
  if enabling: wanted.incl(name) else: wanted.excl(name)
  if wanted.len == 0: stateFail(ecState, "cannot disable the last enabled core", name)
  names = @[]
  for item in wanted: names.add(item)
  names.sort(system.cmp[string])
  if not check.isNil: check(old.enabled, names)
  true

proc mutate(paths: StatePaths; name: string; enabling: bool;
            check: TransitionCheck; dryRun = false) =
  validateName(name)
  # A change that leaves the effective set as it is succeeds without writing
  # anything, not even the state parents or lock (§21.14).
  let current = readEnabledState(paths)
  if dryRun:
    # §21.14: `--now` validates the persistent change before the live step so
    # a predictable failure leaves both states untouched. Nothing is written.
    var ignored: seq[string]
    discard planChange(current, name, enabling, check, ignored)
    return
  if (name in current.enabled) == enabling: return
  ensureDirectory(parentDir(paths.enabledDir))
  ensureDirectory(parentDir(paths.lockFile))
  paths.withStateLock(proc() =
    cleanTemporaries(paths)
    let old = readEnabledState(paths)
    var names: seq[string]
    if not planChange(old, name, enabling, check, names): return
    if not old.initialized:
      materialize(paths, names)
    elif enabling:
      createMarker(paths.enabledDir, name)
    else:
      let marker = paths.enabledDir / name
      if unlink(marker.cstring) != 0: raiseOSError(osLastError(), marker)
      syncDir(paths.enabledDir)
  )

proc fromInvariant(invariant: StateInvariant): TransitionCheck =
  if invariant.isNil: return nil
  result = proc(old, wanted: seq[string]) = invariant(wanted)

proc enableCore*(paths: StatePaths; name: string;
                 invariant: StateInvariant = nil) =
  ## Low-level form without discovery or delegation checks; jumpctl and the
  ## daemon use the `DiscoveryResult` overload.
  mutate(paths, name, true, fromInvariant(invariant))

proc disableCore*(paths: StatePaths; name: string;
                  invariant: StateInvariant = nil) =
  mutate(paths, name, false, fromInvariant(invariant))

proc delegationMap*(found: DiscoveryResult): DelegationMap =
  for core in found.cores: result[core.name] = core.delegationTargets

proc delegationViolations(map: DelegationMap; enabled: seq[string]): seq[(string, string)] =
  ## (dependent, target) pairs where an enabled core delegates to a core that
  ## is not discovered, valid, and enabled (§13.4).
  let enabledSet = enabled.toHashSet
  for core in enabled:
    for target in map.getOrDefault(core):
      if target notin enabledSet or target notin map: result.add((core, target))

proc delegationCheck(map: DelegationMap; name: string): TransitionCheck =
  ## Fails a change with E_DELEGATION when it breaks a delegation between
  ## enabled cores. Delegations already broken before the change (for example
  ## by an uninstalled target) do not block unrelated changes.
  result = proc(old, wanted: seq[string]) =
    let before = delegationViolations(map, old)
    for (dependent, target) in delegationViolations(map, wanted):
      if (dependent, target) in before: continue
      if dependent == name:
        let why = if target in map: "is not enabled" else: "is not a discovered, valid core"
        stateFail(ecDelegation, "delegation target " & target & " " & why, name)
      stateFail(ecDelegation, "enabled core " & dependent & " delegates to " & target, name)

proc requireDiscovered(found: DiscoveryResult; name: string) =
  for core in found.cores:
    if core.name == name: return
  for rejected in found.rejected:
    if rejected.name == name:
      stateFail(coreErrorCode(rejected.code), rejected.reason, name)
  stateFail(ecNotFound, "core not found: " & name, name)

proc enableCore*(paths: StatePaths; name: string; found: DiscoveryResult) =
  ## `jumpctl cores enable` (§21.14): the core must be discovered and valid and
  ## its delegation targets enabled.
  validateName(name)
  requireDiscovered(found, name)
  mutate(paths, name, true, delegationCheck(delegationMap(found), name))

proc disableCore*(paths: StatePaths; name: string; found: DiscoveryResult) =
  ## `jumpctl cores disable` (§21.14): refuses to empty the enabled set
  ## (E_STATE) or to disable the target of an enabled core (E_DELEGATION).
  mutate(paths, name, false, delegationCheck(delegationMap(found), name))

proc checkEnableCore*(paths: StatePaths; name: string; found: DiscoveryResult) =
  ## Dry run of `enableCore`: raises exactly what it would raise, writes nothing.
  validateName(name)
  requireDiscovered(found, name)
  mutate(paths, name, true, delegationCheck(delegationMap(found), name), dryRun = true)

proc checkDisableCore*(paths: StatePaths; name: string; found: DiscoveryResult) =
  ## Dry run of `disableCore`: raises exactly what it would raise, writes nothing.
  mutate(paths, name, false, delegationCheck(delegationMap(found), name), dryRun = true)
