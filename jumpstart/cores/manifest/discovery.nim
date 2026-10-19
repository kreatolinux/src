## Filesystem discovery for Jumpstart cores.
## Manifest parsing is supplied by the caller, so discovery cannot execute it.
import std/[algorithm, os, posix, sets, strutils]
import ./modes
import jumpstartcore/[errors, names]
export modes, names

type
  DiscoveryCode* = enum E_NAME, E_LAYOUT, E_MANIFEST, E_PERMISSION, E_VERSION
  ManifestInfo* = object
    name*: string
    modes*: set[CoreMode]
    referencedPaths*: seq[string]
    incompatibleVersion*: bool
    delegationTargets*: seq[string] ## Cores named by `delegate` backends in this mode.
  ManifestInspector* = proc(path: string): ManifestInfo {.closure.}
  CoreRoot* = object
    path*: string
    trustedUid*: Uid ## Trusted owner of a user root; ignored for the system root.
    isUserRoot*: bool
  DiscoveredCore* = object
    name*: string
    path*: string
    sourceRoot*: string
    delegationTargets*: seq[string]
  RejectedCore* = object
    name*: string
    path*: string
    code*: DiscoveryCode
    reason*: string
  DiscoveryResult* = object
    cores*: seq[DiscoveredCore]
    rejected*: seq[RejectedCore]
  LstatProc* = proc(path: string; st: var Stat): cint {.closure.}
    ## lstat(2) semantics: 0 on success, -1 with errno set on failure.
  DiscoveryOptions* = object
    systemOwner*: Uid ## Trusted owner of the system core root (§8.3: root).
    lstat*: LstatProc ## nil uses lstat(2); tests inject ownership and modes.
  DiscoveryError = object of ValueError
    code: DiscoveryCode

const DiscoveryCodes: array[DiscoveryCode, CoreErrorCode] =
  [ecName, ecLayout, ecManifest, ecPermission, ecVersion]

proc coreErrorCode*(code: DiscoveryCode): CoreErrorCode = DiscoveryCodes[code]

proc discoveryCode*(code: CoreErrorCode; fallback = E_MANIFEST): DiscoveryCode =
  for candidate in DiscoveryCode:
    if DiscoveryCodes[candidate] == code: return candidate
  fallback

proc fail(code: DiscoveryCode; text: string) {.noreturn.} =
  var e = newException(DiscoveryError, text)
  e.code = code
  raise e

proc lstatChecked(opts: DiscoveryOptions; path: string): Stat =
  let rc = if opts.lstat.isNil: posix.lstat(path.cstring, result)
           else: opts.lstat(path, result)
  if rc != 0: raiseOSError(osLastError(), path)

proc trusted(st: Stat; owner: Uid): bool =
  st.st_uid == Uid(0) or st.st_uid == owner

proc checkOwnerAndMode(st: Stat; path: string; owner: Uid) =
  if not st.trusted(owner): fail(E_PERMISSION, "untrusted owner: " & path)
  if (st.st_mode and Mode(0o022)) != 0:
    fail(E_PERMISSION, "group/other writable: " & path)

proc rootFail(code: CoreErrorCode; text: string) {.noreturn.} =
  raise newCoreError(code, text)

proc ownerFor(root: CoreRoot; opts: DiscoveryOptions): Uid =
  ## §8.3: the trusted owner is root for the system core root and the user for
  ## the user core root. Root ownership is always accepted as well.
  if root.isUserRoot: root.trustedUid else: opts.systemOwner

proc checkParents(path: string; owner: Uid; opts: DiscoveryOptions) =
  ## Each parent must be a directory owned by the trusted owner or root and not
  ## group/other writable. A symlinked parent is followed rather than rejected
  ## (only the root itself must not be a link), so its owner is checked and the
  ## resolved chain is checked as well.
  var current = path
  while true:
    let st = opts.lstatChecked(current)
    if S_ISLNK(st.st_mode):
      if not st.trusted(owner):
        rootFail(ecPermission, "untrusted owner: " & current)
    elif not S_ISDIR(st.st_mode):
      rootFail(ecLayout, "core root parent is not a directory: " & current)
    elif not st.trusted(owner):
      rootFail(ecPermission, "untrusted owner: " & current)
    elif (st.st_mode and Mode(0o022)) != 0:
      rootFail(ecPermission, "group/other writable: " & current)
    let parent = parentDir(current)
    if parent.len == 0 or parent == current: break
    current = parent

proc checkRoot(root: CoreRoot; opts: DiscoveryOptions): bool =
  ## Returns false when the root does not exist. Every other problem with the
  ## root or its parents fails discovery as a whole.
  let path = normalizedPath(absolutePath(root.path))
  let owner = root.ownerFor(opts)
  var st: Stat
  let rc = if opts.lstat.isNil: posix.lstat(path.cstring, st) else: opts.lstat(path, st)
  if rc != 0:
    let err = osLastError()
    if err == OSErrorCode(ENOENT): return false
    rootFail(if err == OSErrorCode(EACCES): ecPermission else: ecIo,
             "cannot stat core root " & path & ": " & osErrorMsg(err))
  if S_ISLNK(st.st_mode): rootFail(ecLayout, "core root is a symbolic link: " & path)
  if not S_ISDIR(st.st_mode): rootFail(ecLayout, "core root is not a directory: " & path)
  if not st.trusted(owner): rootFail(ecPermission, "untrusted owner: " & path)
  if (st.st_mode and Mode(0o022)) != 0:
    rootFail(ecPermission, "group/other writable: " & path)
  try:
    let parent = parentDir(path)
    if parent.len > 0 and parent != path:
      checkParents(parent, owner, opts)
      let resolved = expandFilename(parent)
      if resolved != parent: checkParents(resolved, owner, opts)
  except OSError as e:
    rootFail(if e.errorCode == EACCES: ecPermission else: ecIo,
             "cannot check core root parents of " & path & ": " & e.msg)
  true

proc sortedChildren(path: string): seq[string] =
  ## checkDir makes an unreadable directory an error instead of empty (§8.2).
  for kind, child in walkDir(path, relative = false, checkDir = true):
    result.add(child)
  result.sort(proc(a, b: string): int = cmp(extractFilename(a), extractFilename(b)))

proc checkTree(path: string; owner: Uid; opts: DiscoveryOptions) =
  let st = opts.lstatChecked(path)
  if S_ISLNK(st.st_mode): fail(E_LAYOUT, "symbolic link: " & path)
  checkOwnerAndMode(st, path, owner)
  if S_ISDIR(st.st_mode):
    for child in sortedChildren(path): checkTree(child, owner, opts)
  elif not S_ISREG(st.st_mode):
    fail(E_LAYOUT, "not a regular file or directory: " & path)

proc containedRelative(path: string): bool =
  if path.len == 0 or path.isAbsolute: return false
  var depth = 0
  for part in path.split({'/', '\\'}):
    if part.len == 0 or part == ".": continue
    if part == "..":
      if depth == 0: return false
      dec depth
    else: inc depth
  true

proc reject(result: var DiscoveryResult; name, path: string;
            code: DiscoveryCode; reason: string) =
  result.rejected.add RejectedCore(name: name, path: path, code: code, reason: reason)

proc inspectManifest(inspect: ManifestInspector; manifest: string): ManifestInfo =
  ## The loader's own CoreError code is kept (ManifestError carries E_VERSION
  ## for an incompatible `jumpstart` range, E_LAYOUT for an escaping path);
  ## codes outside the §8.3 table and uncoded errors are manifest errors.
  try: result = inspect(manifest)
  except CoreError as e: fail(discoveryCode(e.code), e.msg)
  except CatchableError as e: fail(E_MANIFEST, e.msg)

proc discoverCores*(mode: CoreMode; roots: openArray[CoreRoot];
                    inspect: ManifestInspector;
                    options = DiscoveryOptions()): DiscoveryResult =
  ## Roots are processed in caller-provided order (system root first). A
  ## missing root contributes nothing; an unreadable or insecure root raises
  ## CoreError. Invalid children are reported and do not prevent other
  ## children from being discovered.
  if inspect.isNil: raise newException(ValueError, "manifest inspector is required")
  result.cores.add DiscoveredCore(name: "serviceHandler")
  var systemNames = initHashSet[string]()
  for root in roots:
    if not checkRoot(root, options): continue
    let owner = root.ownerFor(options)
    var entries: seq[string]
    try: entries = sortedChildren(root.path)
    except OSError as e:
      rootFail(if e.errorCode == EACCES: ecPermission else: ecIo,
               "cannot read core root " & root.path & ": " & e.msg)
    if not root.isUserRoot:
      # Every direct child is a claim to be a system extension, valid or not,
      # and user cores never shadow one (§7.3).
      for path in entries: systemNames.incl(extractFilename(path))
    for path in entries:
      let name = extractFilename(path)
      try:
        let top = options.lstatChecked(path)
        if not S_ISDIR(top.st_mode) or S_ISLNK(top.st_mode):
          fail(E_LAYOUT, "extension entry is not a directory")
        if not validCoreName(name): fail(E_NAME, "invalid or reserved core name")
        if root.isUserRoot and name in systemNames:
          fail(E_NAME, "user core shadows a system extension")
        checkTree(path, owner, options)
        for child in sortedChildren(path):
          let childName = extractFilename(child)
          if childName notin ["init.kg", "bin", "lib", "share"]:
            fail(E_LAYOUT, "unexpected top-level entry: " & childName)
          if childName in ["bin", "lib", "share"]:
            let childStat = options.lstatChecked(child)
            if not S_ISDIR(childStat.st_mode) or S_ISLNK(childStat.st_mode):
              fail(E_LAYOUT, childName & " is not a directory")
        let manifest = path / "init.kg"
        var mst: Stat
        let mrc = if options.lstat.isNil: posix.lstat(manifest.cstring, mst)
                  else: options.lstat(manifest, mst)
        if mrc != 0 or not S_ISREG(mst.st_mode) or S_ISLNK(mst.st_mode):
          fail(E_MANIFEST, "init.kg missing or not a regular file")
        let info = inspectManifest(inspect, manifest)
        if info.incompatibleVersion: fail(E_VERSION, "incompatible Jumpstart version")
        if info.name != name: fail(E_MANIFEST, "manifest name differs from directory")
        if root.isUserRoot and cmUser notin info.modes:
          fail(E_MANIFEST, "user-root core does not support user mode")
        for referenced in info.referencedPaths:
          if not containedRelative(referenced): fail(E_LAYOUT, "referenced path escapes core")
        if mode notin info.modes: continue
        var targets: seq[string]
        for target in info.delegationTargets:
          if target notin targets: targets.add(target)
        targets.sort(system.cmp[string])
        result.cores.add DiscoveredCore(name: name, path: path,
          sourceRoot: root.path, delegationTargets: targets)
      except DiscoveryError as e:
        result.reject(name, path, e.code, e.msg)
      except OSError as e:
        let code = if e.errorCode in [EACCES, EPERM]: E_PERMISSION else: E_LAYOUT
        result.reject(name, path, code, e.msg)
