## cgroup v2 layout and lifecycle support (§15.1, §7.6 step 4.3). All effects
## are injectable through `CgroupSystem`; `defaultCgroupSystem` is the
## production implementation over a real cgroup2 filesystem.
##
## cgroupfs semantics the helpers rely on:
## - a cgroup directory is removed with rmdir(2) even though it still lists its
##   interface files; unlinking interface files fails with EPERM. Directories
##   must therefore be removed bottom-up with `removeDir` = rmdir only;
## - rmdir fails with EBUSY while the cgroup (or a descendant) holds processes.
import std/[algorithm, monotimes, options, os, posix, sets, strutils, times]
import ./[errors, names]

type
  CgroupError* = object of CatchableError
  CgroupSystem* = object
    exists*: proc(path: string): bool {.closure.}
    isDir*: proc(path: string): bool {.closure.}
    makeDir*: proc(path: string) {.closure.}
    readFile*: proc(path: string): string {.closure.}
    writeFile*: proc(path, value: string) {.closure.}
    removeDir*: proc(path: string) {.closure.}
      ## Remove ONE empty cgroup directory (rmdir semantics, never recursive).
    chownPath*: proc(path: string; uid, gid: int) {.closure.}
    now*: proc(): float {.closure.}
    pause*: proc(milliseconds: int) {.closure.}
    listDirs*: proc(path: string): seq[string] {.closure.}
      ## Names of the immediate child directories (child cgroups) of path.
    signalPid*: proc(pid: int; signal: cint) {.closure.}
      ## Used only by the freeze+SIGKILL fallback when cgroup.kill is absent.
  CoreCgroups* = object
    core*, control*, units*: string
  UserCgroups* = object
    ## users/UID/ (delegated), its daemon/ leaf and the cores/ root that the
    ## user daemon manages (§15.1 layout).
    user*, daemon*, cores*: string
  CgroupHierarchy* = object
    mount*, jumpstart*, cores*, users*: string

const
  CgroupKillTimeoutSeconds* = 5.0
  DelegatedFiles* = ["cgroup.procs", "cgroup.threads", "cgroup.subtree_control"]
  UnitCgroupSuffix* = ".unit"
  MaxCgroupNameBytes* = 255
    ## kernfs limit for one cgroup directory name.
  MaxNestedUnitDepth* = 64
    ## Longest chain of components `ensureNestedUnitCgroup` accepts.

proc fail(message: string) {.noreturn.} =
  raise newException(CgroupError, message)

proc validAbsolute(path: string): bool =
  if path.len == 0 or not path.isAbsolute or '\0' in path: return false
  for part in path.split('/'):
    if part == "..": return false
  true

proc checkedRoot(root: string): string =
  if not validAbsolute(root): fail("cgroup root must be absolute and non-traversing")
  result = normalizedPath(root)
  if result == "/": fail("refusing filesystem root as cgroup root")

proc cgroupHierarchy*(mountPoint = "/sys/fs/cgroup"): CgroupHierarchy =
  let mount = checkedRoot(mountPoint)
  CgroupHierarchy(mount: mount, jumpstart: mount / "jumpstart",
                  cores: mount / "jumpstart" / "cores",
                  users: mount / "jumpstart" / "users")

proc coreCgroups*(coresRoot, coreName: string): CoreCgroups =
  let root = checkedRoot(coresRoot)
  if not validCoreName(coreName, extension = false): fail("invalid core name")
  result.core = root / coreName
  result.control = result.core / "control"
  result.units = result.core / "units"

proc userCgroups*(usersRoot: string; uid: int): UserCgroups =
  let root = checkedRoot(usersRoot)
  if uid <= 0: fail("user cgroups require a non-root UID")
  result.user = root / $uid
  result.daemon = result.user / "daemon"
  result.cores = result.user / "cores"

proc validUnitCgroupName*(name: string): bool =
  ## §15.1 rule 7: the name of one cgroup directory a core creates below
  ## `units/` (the whole name, including the `.unit` suffix that the caller
  ## adds). It is valid when it
  ## - ends in `.unit` and has at least one byte before the suffix,
  ## - is at most 255 bytes (cgroup v2 directory names are kernfs names),
  ## - contains no `/`, NUL, or ASCII control character (the kernel itself
  ##   rejects a newline, and a control character would break the line
  ##   format of /proc/PID/cgroup), and
  ## - is not `.` or `..`.
  ## Nothing else is restricted: `\`, `%`, `@`, `:`, and spaces are valid.
  ## No collision with a cgroup interface file (`cgroup.procs`, `memory.max`,
  ## ...) is possible, because the suffix `.unit` is none of their names'
  ## endings.
  if name.len <= UnitCgroupSuffix.len or name.len > MaxCgroupNameBytes or
      not name.endsWith(UnitCgroupSuffix): return false
  if name in [".", ".."]: return false
  for c in name:
    if c <= '\x1f' or c == '\x7f' or c == '/': return false
  true

proc unitCgroupName*(unit: string): string =
  ## serviceHandler's native per-unit cgroup name (§15.1 rule 6). Native unit
  ## names never contain `/`; anything that would not form a valid name fails,
  ## and a backslash always has (the general rule 7 accepts it, this native
  ## name function keeps its original stricter behavior).
  result = unit & UnitCgroupSuffix
  if '\\' in unit or not validUnitCgroupName(result):
    fail("unit name cannot form a cgroup name: " & unit)

proc unitCgroupPath*(unitsRoot, name: string): string =
  let root = checkedRoot(unitsRoot)
  if not validUnitCgroupName(name): fail("invalid unit cgroup name")
  root / name

proc requireSystem(sys: CgroupSystem) =
  if sys.exists.isNil or sys.isDir.isNil or sys.makeDir.isNil or
      sys.readFile.isNil or sys.writeFile.isNil or sys.removeDir.isNil:
    fail("incomplete cgroup system abstraction")

proc requireTreeOps(sys: CgroupSystem) =
  requireSystem(sys)
  if sys.listDirs.isNil: fail("cgroup listing operation unavailable")
  if sys.now.isNil or sys.pause.isNil: fail("timing operations unavailable")

proc controllerNames*(text: string): seq[string] =
  var seen = initHashSet[string]()
  for item in text.splitWhitespace:
    for c in item:
      if c notin {'a'..'z', '0'..'9', '_'}: fail("invalid controller: " & item)
    if item notin seen:
      seen.incl item
      result.add item
  result.sort(system.cmp[string])

proc enableControllers*(path: string; sys: CgroupSystem) =
  ## Enable in `path/cgroup.subtree_control` every controller available from
  ## the parent (listed in `path/cgroup.controllers`).
  requireSystem(sys)
  let root = checkedRoot(path)
  if not sys.isDir(root): fail("cgroup is not a directory: " & root)
  let controllers = controllerNames(sys.readFile(root / "cgroup.controllers"))
  if controllers.len > 0:
    var values: seq[string]
    for controller in controllers: values.add("+" & controller)
    try: sys.writeFile(root / "cgroup.subtree_control", values.join(" "))
    except CgroupError: raise
    except CatchableError as e:
      fail("cannot enable controllers in " & root & ": " & e.msg)

proc ensureCgroupDir(path: string; sys: CgroupSystem) =
  if not sys.isDir(path):
    if sys.exists(path): fail("cgroup path is not a directory: " & path)
    try: sys.makeDir(path)
    except CatchableError as e: fail("cannot create cgroup " & path & ": " & e.msg)

proc prepareSystemHierarchy*(hierarchy: CgroupHierarchy; sys: CgroupSystem) =
  ## System mode: create jumpstart/, jumpstart/cores/ and jumpstart/users/ and
  ## enable every available controller in them (§15.1 rule 1). The mount root
  ## must delegate controllers to jumpstart/ for them to be available there;
  ## PID 1 stays in the root cgroup, which is exempt from the leaf rule.
  requireSystem(sys)
  if not sys.exists(hierarchy.mount / "cgroup.controllers"):
    fail("cgroup v2 unavailable at " & hierarchy.mount)
  enableControllers(hierarchy.mount, sys)
  ensureCgroupDir(hierarchy.jumpstart, sys)
  enableControllers(hierarchy.jumpstart, sys)
  ensureCgroupDir(hierarchy.cores, sys)
  enableControllers(hierarchy.cores, sys)
  ensureCgroupDir(hierarchy.users, sys)
  enableControllers(hierarchy.users, sys)

proc createCoreCgroups*(coresRoot, coreName: string; sys: CgroupSystem): CoreCgroups =
  ## Creates cores/CORE/{control,units}. The parent of `coresRoot` must exist
  ## (jumpstart/ in system mode, the delegated users/UID/ in user mode); the
  ## cores root itself is created when missing (a user daemon creates
  ## users/UID/cores/ in its delegated subtree).
  requireSystem(sys)
  result = coreCgroups(coresRoot, coreName)
  let root = checkedRoot(coresRoot)
  let parent = parentDir(root)
  if not sys.isDir(parent) or not sys.exists(parent / "cgroup.controllers"):
    fail("cgroup hierarchy unavailable: " & parent)
  enableControllers(parent, sys)
  ensureCgroupDir(root, sys)
  if not sys.exists(root / "cgroup.controllers"): fail("cgroup v2 unavailable")
  enableControllers(root, sys)
  if sys.exists(result.core): fail("core cgroup already exists")
  sys.makeDir(result.core)
  enableControllers(result.core, sys)
  sys.makeDir(result.control)
  sys.makeDir(result.units)
  enableControllers(result.units, sys)

proc createUnitCgroup*(layout: CoreCgroups; name: string; sys: CgroupSystem): string =
  requireSystem(sys)
  if checkedRoot(layout.units) != normalizedPath(layout.core / "units"):
    fail("invalid core cgroup layout")
  result = unitCgroupPath(layout.units, name)
  if sys.exists(result): fail("unit cgroup already exists")
  sys.makeDir(result)

proc ensureUnitCgroup*(layout: CoreCgroups; name: string; sys: CgroupSystem): string =
  ## Like createUnitCgroup but reuses an existing directory (a native service
  ## restarted after its previous processes were killed).
  requireSystem(sys)
  if checkedRoot(layout.units) != normalizedPath(layout.core / "units"):
    fail("invalid core cgroup layout")
  result = unitCgroupPath(layout.units, name)
  ensureCgroupDir(result, sys)

proc nestedPath(layout: CoreCgroups; parts: openArray[string]): string =
  if checkedRoot(layout.units) != normalizedPath(layout.core / "units"):
    fail("invalid core cgroup layout")
  if parts.len == 0: fail("nested unit cgroup needs at least one component")
  if parts.len > MaxNestedUnitDepth: fail("nested unit cgroup is too deep")
  result = checkedRoot(layout.units)
  for part in parts:
    if not validUnitCgroupName(part): fail("invalid unit cgroup name")
    result = result / part

proc ensureNestedUnitCgroup*(layout: CoreCgroups; parts: openArray[string];
                             sys: CgroupSystem; enableLast = false): string =
  ## Create (or reuse) `units/PART0/PART1/.../PARTn` below the core's `units/`
  ## and return its path. Every component is validated with
  ## `validUnitCgroupName`, so each ends in `.unit` (§15.1 rule 7). A cgroup
  ## that has children cannot hold processes, so every component except the
  ## last is a pure slice: its available controllers are enabled in its
  ## `cgroup.subtree_control` right after it exists, which makes them
  ## available to the next component. The last component gets controllers only
  ## with `enableLast` (for a slice, not for a unit that holds processes).
  ## Nothing is chowned: the components belong to whoever created them, and a
  ## delegated core's account may create them because it owns `units/` and
  ## its delegation files (§15.1 rule 4).
  requireSystem(sys)
  discard nestedPath(layout, parts)
  var path = checkedRoot(layout.units)
  for i, part in parts:
    path = path / part
    ensureCgroupDir(path, sys)
    if i < parts.high or enableLast: enableControllers(path, sys)
  result = path

proc removeNestedUnitCgroup*(layout: CoreCgroups; parts: openArray[string];
                             sys: CgroupSystem): int =
  ## Remove the last component with `rmdir` and then each ancestor below
  ## `units/` bottom-up, stopping at the first ancestor that cannot be removed
  ## (it still has other children or processes). Never recursive. A component
  ## that does not exist is skipped. A failure to remove the LAST component
  ## (children or processes remain) raises `CgroupError`; an ancestor that is
  ## still in use ends the walk silently. Returns the number of directories
  ## removed.
  requireSystem(sys)
  discard nestedPath(layout, parts)
  for depth in countdown(parts.len, 1):
    let path = nestedPath(layout, parts[0 ..< depth])
    if not sys.isDir(path): continue
    try: sys.removeDir(path)
    except CatchableError as e:
      if depth == parts.len: fail("cannot remove cgroup " & path & ": " & e.msg)
      return
    inc result

proc joinCgroup*(cgroup: string; pid: int; sys: CgroupSystem) =
  requireSystem(sys)
  if pid <= 0: fail("invalid process id")
  let path = checkedRoot(cgroup)
  if not sys.isDir(path): fail("target cgroup unavailable")
  sys.writeFile(path / "cgroup.procs", $pid)

proc delegateDir*(dir: string; uid, gid: int; sys: CgroupSystem) =
  if not sys.isDir(dir): fail("delegation target unavailable: " & dir)
  sys.chownPath(dir, uid, gid)
  for file in DelegatedFiles:
    if not sys.exists(dir / file): fail("delegation interface unavailable: " & file)
    sys.chownPath(dir / file, uid, gid)

proc delegateCore*(layout: CoreCgroups; uid, gid: int; sys: CgroupSystem) =
  ## §15.1 rule 4: exactly cores/CORE/ and units/ plus their three delegation
  ## files change owner. control/ and every limit file stay root-owned.
  requireSystem(sys)
  if sys.chownPath.isNil: fail("ownership operation unavailable")
  if uid <= 0 or gid < 0: fail("delegation requires a non-root account")
  delegateDir(layout.core, uid, gid, sys)
  delegateDir(layout.units, uid, gid, sys)

proc createUserCgroups*(usersRoot: string; uid: int; sys: CgroupSystem): UserCgroups =
  ## §7.6 step 4.3: users/UID/ and its daemon/ leaf. An existing subtree
  ## from a previous daemon is reused only if it holds no processes.
  requireSystem(sys)
  result = userCgroups(usersRoot, uid)
  let root = checkedRoot(usersRoot)
  if not sys.isDir(root) or not sys.exists(root / "cgroup.controllers"):
    fail("cgroup hierarchy unavailable: " & root)
  ensureCgroupDir(result.user, sys)
  ensureCgroupDir(result.daemon, sys)

proc delegateUser*(layout: UserCgroups; uid, gid: int; sys: CgroupSystem) =
  ## Delegates users/UID/ exactly as §15.1 rule 4: the directory and its
  ## cgroup.procs, cgroup.threads and cgroup.subtree_control, nothing else.
  requireSystem(sys)
  if sys.chownPath.isNil: fail("ownership operation unavailable")
  if uid <= 0 or gid < 0: fail("delegation requires a non-root account")
  delegateDir(layout.user, uid, gid, sys)

proc populated*(events: string): bool =
  var found = false
  for line in events.splitLines:
    let fields = line.splitWhitespace
    if fields.len == 2 and fields[0] == "populated":
      if found or fields[1] notin ["0", "1"]: fail("invalid cgroup.events")
      found = true
      result = fields[1] == "1"
  if not found: fail("cgroup.events lacks populated state")

proc cgroupPopulated*(path: string; sys: CgroupSystem): bool =
  ## A missing cgroup holds no processes.
  requireSystem(sys)
  let root = checkedRoot(path)
  if not sys.isDir(root): return false
  populated(sys.readFile(root / "cgroup.events"))

proc childCgroups(path: string; sys: CgroupSystem): seq[string] =
  for name in sys.listDirs(path):
    if name.len == 0 or name in [".", ".."] or '/' in name or '\0' in name:
      fail("invalid child cgroup name under " & path)
    result.add path / name
  result.sort(system.cmp[string])

proc subtree(path: string; sys: CgroupSystem): seq[string] =
  ## Pre-order listing of path and all descendant cgroups.
  result.add path
  for child in childCgroups(path, sys): result.add subtree(child, sys)

proc parsePids(text: string): seq[int] =
  for line in text.splitLines:
    let item = line.strip
    if item.len == 0: continue
    try: result.add parseInt(item)
    except ValueError: fail("invalid cgroup.procs content")

proc waitEmpty(root: string; sys: CgroupSystem; timeoutSeconds: float) =
  let deadline = sys.now() + timeoutSeconds
  while populated(sys.readFile(root / "cgroup.events")):
    if sys.now() >= deadline: fail("timed out waiting for empty cgroup: " & root)
    sys.pause(10)

proc killCgroup*(path: string; sys: CgroupSystem;
                 timeoutSeconds = CgroupKillTimeoutSeconds) =
  ## Kill every process in the subtree rooted at path and wait up to
  ## `timeoutSeconds` for `populated 0`. Uses cgroup.kill (Linux >= 5.14) and
  ## otherwise freezes the subtree, SIGKILLs every member and thaws it, so no
  ## process can fork past the kill. A missing cgroup is already empty.
  requireTreeOps(sys)
  if timeoutSeconds < 0: fail("invalid timeout")
  let root = checkedRoot(path)
  if not sys.isDir(root): return
  if sys.exists(root / "cgroup.kill"):
    sys.writeFile(root / "cgroup.kill", "1")
  else:
    if sys.signalPid.isNil: fail("cgroup.kill unavailable and no signal fallback")
    let canFreeze = sys.exists(root / "cgroup.freeze")
    if canFreeze: sys.writeFile(root / "cgroup.freeze", "1")
    try:
      for cgroup in subtree(root, sys):
        for pid in parsePids(sys.readFile(cgroup / "cgroup.procs")):
          if pid > 1: sys.signalPid(pid, SIGKILL)
    finally:
      if canFreeze: sys.writeFile(root / "cgroup.freeze", "0")
  waitEmpty(root, sys, timeoutSeconds)

proc removeCgroupTree*(path: string; sys: CgroupSystem;
                       timeoutSeconds = CgroupKillTimeoutSeconds) =
  ## Remove path and every descendant cgroup bottom-up with rmdir only.
  ## EBUSY right after a kill (exit still being accounted) is retried until
  ## the timeout. A missing cgroup is not an error.
  requireTreeOps(sys)
  let root = checkedRoot(path)
  if not sys.isDir(root): return
  for child in childCgroups(root, sys): removeCgroupTree(child, sys, timeoutSeconds)
  let deadline = sys.now() + timeoutSeconds
  while true:
    try:
      sys.removeDir(root)
      return
    except CatchableError as e:
      if not sys.isDir(root): return
      if sys.now() >= deadline: fail("cannot remove cgroup " & root & ": " & e.msg)
      sys.pause(10)

proc killCore*(layout: CoreCgroups; sys: CgroupSystem;
               timeoutSeconds = CgroupKillTimeoutSeconds) =
  ## §15.1 rule 5: write 1 to cgroup.kill of cores/CORE/, wait up to 5 seconds
  ## for populated 0, then remove the whole subtree (including every *.unit
  ## cgroup the core created).
  killCgroup(layout.core, sys, timeoutSeconds)
  removeCgroupTree(layout.core, sys, timeoutSeconds)

proc killUnitCgroup*(path: string; sys: CgroupSystem;
                     timeoutSeconds = CgroupKillTimeoutSeconds) =
  ## Native `stop` (§15.1 rule 6): reach every process of the service, then
  ## remove its units/UNIT.unit cgroup.
  killCgroup(path, sys, timeoutSeconds)
  removeCgroupTree(path, sys, timeoutSeconds)

proc killUserCgroups*(layout: UserCgroups; sys: CgroupSystem;
                      timeoutSeconds = CgroupKillTimeoutSeconds) =
  ## §7.6 step 5: kill anything left in users/UID/ and remove the subtree.
  killCgroup(layout.user, sys, timeoutSeconds)
  removeCgroupTree(layout.user, sys, timeoutSeconds)

proc removeCoreCgroups*(layout: CoreCgroups; sys: CgroupSystem) =
  ## Remove cores/CORE/ bottom-up (unit cgroups, units/, control/, the core)
  ## with rmdir only. Fails while any process remains; use killCore to end
  ## processes first.
  removeCgroupTree(layout.core, sys)

proc defaultCgroupSystem*(): CgroupSystem =
  result.exists = proc(path: string): bool = fileExists(path) or dirExists(path)
  result.isDir = proc(path: string): bool = dirExists(path)
  result.makeDir = proc(path: string) =
    if posix.mkdir(path.cstring, Mode(0o755)) != 0: raiseOSError(osLastError(), path)
  result.readFile = proc(path: string): string = system.readFile(path)
  result.writeFile = proc(path, value: string) =
    # Interface files take one write(2); a short or failed write is an error.
    let fd = posix.open(path.cstring, O_WRONLY or O_CLOEXEC)
    if fd < 0: raiseOSError(osLastError(), path)
    defer: discard posix.close(fd)
    if value.len > 0:
      let written = posix.write(fd, unsafeAddr value[0], value.len)
      if written != value.len: raiseOSError(osLastError(), path)
  result.removeDir = proc(path: string) =
    if posix.rmdir(path.cstring) != 0: raiseOSError(osLastError(), path)
  result.chownPath = proc(path: string; uid, gid: int) =
    if posix.lchown(path.cstring, Uid(uid), Gid(gid)) != 0: raiseOSError(osLastError(), path)
  # Monotonic: a wall-clock step must not expire or stretch a kill deadline.
  result.now = proc(): float = float(getMonoTime().ticks) / 1e9
  result.pause = proc(milliseconds: int) = sleep(milliseconds)
  result.listDirs = proc(path: string): seq[string] =
    for kind, child in walkDir(path, relative = true):
      if kind == pcDir: result.add child
  result.signalPid = proc(pid: int; signal: cint) =
    if posix.kill(Pid(pid), signal) != 0 and osLastError() != OSErrorCode(ESRCH):
      raiseOSError(osLastError())

proc decodeMountField(field: string): string =
  var i = 0
  while i < field.len:
    if field[i] == '\\':
      if i + 3 >= field.len or field[i+1..i+3] notin ["040", "011", "012", "134"]:
        fail("invalid mountinfo escape")
      result.add char(parseOctInt(field[i+1..i+3])); i += 4
    else: result.add field[i]; inc i

proc mountInfoFsType*(text, mountPoint: string): string =
  ## Return the filesystem type mounted exactly at mountPoint (the topmost,
  ## i.e. last listed, mount when several are stacked). Linux mountinfo uses
  ## octal escapes in path fields; malformed records fail closed.
  let target = checkedRoot(mountPoint)
  for line in text.splitLines:
    if line.len == 0: continue
    let halves = line.split(" - ", maxsplit = 1)
    if halves.len != 2: fail("invalid mountinfo record")
    let left = halves[0].splitWhitespace
    let right = halves[1].splitWhitespace
    if left.len < 6 or right.len < 1: fail("invalid mountinfo record")
    if decodeMountField(left[4]) == target:
      result = right[0]

proc selfCgroupPath*(procSelfCgroup: string): string =
  ## The cgroup v2 path ("0::/path") of a /proc/PID/cgroup file, or "".
  for line in procSelfCgroup.splitLines:
    if line.startsWith("0::"): return line[3 .. ^1]

proc unitOfPid*(layout: CoreCgroups; procCgroupText: string): Option[seq[string]] =
  ## The cgroup components below `units/` that own a process, from the text of
  ## its `/proc/PID/cgroup`: the maximal chain of components that all end in
  ## `.unit`, starting at the first one. `none` when the process is not below
  ## this core's `units/`, or sits in `units/` itself, or its first component
  ## does not end in `.unit`. Components below the first one that does NOT end
  ## in `.unit` (the sub-cgroups of a delegated service) are not part of the
  ## chain, so they belong to the unit that owns the chain's last component
  ## and a service cannot claim another unit's name by naming a sub-cgroup.
  ## The path in /proc is relative to the cgroup namespace root, so it is
  ## matched on component boundaries against the tail of `layout.units`
  ## (`.../cores/CORE/units`). The core decodes the returned components.
  let path = selfCgroupPath(procCgroupText)
  if path.len == 0 or path[0] != '/': return
  let unitsParts = checkedRoot(layout.units).split('/')
  var tail: seq[string]
  for part in unitsParts:
    if part.len > 0: tail.add part
  # tail = [..., "cores", CORE, "units"]
  if tail.len < 3 or tail[^1] != "units": return
  var comps: seq[string]
  for part in path.split('/'):
    if part.len > 0: comps.add part
  for i in 0 .. comps.len - 3:
    if comps[i] != "cores" or comps[i + 1] != tail[^2] or comps[i + 2] != "units": continue
    # comps[0 ..< i] must be the last components of tail[0 ..< ^3].
    let prefix = comps[0 ..< i]
    let base = tail[0 ..< tail.len - 3]
    if prefix.len > base.len or base[base.len - prefix.len .. ^1] != prefix: continue
    var chain: seq[string]
    for part in comps[i + 3 .. ^1]:
      if not validUnitCgroupName(part): break
      chain.add part
    if chain.len > 0: return some(chain)
    return
  none(seq[string])

proc cgroupV2Mounted*(mountInfo, mountPoint: string; sys: CgroupSystem): bool =
  ## True when a cgroup2 filesystem is the topmost mount at mountPoint.
  requireSystem(sys)
  mountInfoFsType(mountInfo, mountPoint) == "cgroup2" and
    sys.exists(checkedRoot(mountPoint) / "cgroup.controllers")

proc userDelegationAvailable*(mountPoint: string; uid: int;
                              procSelfCgroup: string; sys: CgroupSystem): bool =
  ## User mode (§15.1, §7.6 step 8): the daemon has a delegated subtree only if
  ## the system daemon started it in jumpstart/users/UID/daemon/ and the
  ## subtree exists. A hand-started daemon has none.
  requireSystem(sys)
  if uid <= 0: return false
  let layout = userCgroups(cgroupHierarchy(mountPoint).users, uid)
  selfCgroupPath(procSelfCgroup) == "/jumpstart/users/" & $uid & "/daemon" and
    sys.isDir(layout.user) and sys.exists(layout.user / "cgroup.procs")

proc requireCgroups*(available: bool; core: string) =
  ## Step 4 of §20.3 for extension cores.
  if not available:
    raise newCoreError(ecCgroup, "cgroup v2 (or a delegated subtree) is unavailable", core)

when defined(linux):
  {.emit: """
#define _GNU_SOURCE
#include <errno.h>
#include <sys/mount.h>
static int js_mount_cgroup2(const char *path) {
  if (mount("cgroup2", path, "cgroup2", MS_NOSUID|MS_NODEV|MS_NOEXEC, "nsdelegate") < 0)
    return errno;
  return 0;
}
""".}
  proc linuxMountCgroup2(path: cstring): cint {.importc: "js_mount_cgroup2", nodecl.}

proc ensureCgroupV2*(mountPoint = "/sys/fs/cgroup";
                     mountInfoPath = "/proc/self/mountinfo";
                     filesystemsPath = "/proc/filesystems") =
  ## System-mode early-boot helper (§15.1). Mounts cgroup2 with nsdelegate when
  ## nothing is mounted at mountPoint. Never overlays a v1/hybrid or unrelated
  ## existing mount. Every failure raises CoreError with E_CGROUP: the daemon
  ## then records cgroups as unavailable, so extension cores fail to load with
  ## E_CGROUP and serviceHandler runs without cgroups.
  let target = try: checkedRoot(mountPoint)
               except CgroupError as e: raise newCoreError(ecCgroup, e.msg)
  when defined(linux):
    var kind: string
    try: kind = mountInfoFsType(system.readFile(mountInfoPath), target)
    except CatchableError as e:
      raise newCoreError(ecCgroup, "cannot read mount table: " & e.msg)
    if kind.len > 0:
      if kind != "cgroup2":
        raise newCoreError(ecCgroup, "existing hierarchy at " & target &
          " is " & kind & ", not cgroup v2")
      if not fileExists(target / "cgroup.controllers"):
        raise newCoreError(ecCgroup, "invalid cgroup v2 mount")
      return
    var filesystems: string
    try: filesystems = system.readFile(filesystemsPath)
    except CatchableError as e:
      raise newCoreError(ecCgroup, "cannot read supported filesystems: " & e.msg)
    var supported = false
    for line in filesystems.splitLines:
      let fields = line.splitWhitespace
      if fields.len > 0 and fields[^1] == "cgroup2": supported = true
    if not supported:
      raise newCoreError(ecCgroup, "kernel does not support cgroup v2")
    if not dirExists(target):
      try: createDir(target)
      except CatchableError as e:
        raise newCoreError(ecCgroup, "cannot create " & target & ": " & e.msg)
    let code = linuxMountCgroup2(target.cstring)
    if code != 0:
      raise newCoreError(ecCgroup, "mount cgroup2 failed: " & $strerror(code))
    if not fileExists(target / "cgroup.controllers"):
      raise newCoreError(ecCgroup, "mounted cgroup v2 lacks controller interface")
  else:
    discard mountInfoPath
    discard filesystemsPath
    raise newCoreError(ecCgroup, "cgroup v2 is unavailable on this platform")
