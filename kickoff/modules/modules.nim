## Kernel module selection for the initramfs.
##
## The initramfs has to carry exactly the modules needed to reach the root
## filesystem, plus their dependencies. `modules.dep` already describes that
## graph; this module reads it and resolves a requested set of module names
## transitively.
##
## Modules built into the kernel are skipped: they have no .ko to copy and
## requesting them would otherwise silently produce a broken archive. The
## built-in list comes from `modules.builtin` in the same directory.

import std/[algorithm, os, sets, strutils, tables]

type
  RootfsLayout* = enum
    ## How the root filesystem will be reached at boot. Drives module choice.
    rlErofsDisk = "erofs"
    rlSquashfsDisk = "squashfs"
    rlSquashfsIso = "squashfs-iso"

  ModuleIndex* = object
    root*: string                            ## absolute /lib/modules/<version>
    deps*: Table[string, seq[string]]        ## module path -> dependency paths
    byName*: Table[string, seq[string]]      ## "erofs.ko" -> paths
    builtin*: HashSet[string]                ## module paths compiled into the kernel
    builtinNames*: HashSet[string]           ## basenames of those paths ("virtio_blk.ko")

proc parseLayout*(value: string): RootfsLayout =
  case value.toLowerAscii
  of "", "erofs": rlErofsDisk
  of "squashfs": rlSquashfsDisk
  of "squashfs-iso", "iso": rlSquashfsIso
  else:
    raise newException(ValueError,
        "Unknown root filesystem '" & value & "' (use erofs, squashfs or squashfs-iso)")

proc requiredModuleNames*(layout: RootfsLayout): seq[string] =
  ## The modules needed to reach the root for each layout.
  ##
  ## Storage and optical drivers are included even though the Kreato kernel has
  ## them built in: collectModules() skips built-in modules automatically, so
  ## listing them costs nothing here and means the same layout also works on a
  ## kernel where they are loadable. Without them a live medium would not be
  ## found at all on such a kernel, and the failure looks like "no root".
  case layout
  of rlErofsDisk:
    @["erofs", "overlay", "virtio_blk"]
  of rlSquashfsDisk:
    @["squashfs", "loop", "overlay", "virtio_blk"]
  of rlSquashfsIso:
    # The medium may be a CD-ROM or, once written to a USB stick, a plain block
    # device, so both paths are covered.
    @["squashfs", "loop", "isofs", "overlay", "virtio_blk", "sr_mod", "cdrom"]

proc parseModulesDep*(content: string): Table[string, seq[string]] =
  ## Parse modules.dep. Lines are "path: dep dep ..."; continuation lines
  ## beginning with whitespace belong to the previous entry. Malformed lines are
  ## skipped rather than aborting the build: a kernel tree we did not produce may
  ## carry oddities, and a missing module is reported later and more clearly.
  var current = ""
  for rawLine in content.splitLines():
    let line = rawLine.strip()
    if line.len == 0: continue
    let colon = line.find(':')
    if colon < 0:
      # Continuation of the previous entry.
      if current.len > 0:
        for token in line.splitWhitespace():
          result.mgetOrPut(current, @[]).add token
      continue
    let path = line[0 ..< colon].strip()
    if path.len == 0: continue
    current = path
    var deps: seq[string]
    for token in line[colon + 1 .. ^1].splitWhitespace():
      if token.len > 0: deps.add token
    result[path] = deps

proc parseModulesBuiltin*(content: string): HashSet[string] =
  ## Parse modules.builtin: one module path per line, no dependencies.
  for rawLine in content.splitLines():
    let line = rawLine.strip()
    if line.len > 0: result.incl line

proc findModuleRoot*(rootfs, kernelVersion: string): string =
  ## Locate /lib/modules/<version> inside the rootfs. Kreato Linux keeps them in
  ## /usr/lib/modules, so that path is tried first and /lib/modules second for
  ## rootfs trees built with the plain layout.
  for candidate in ["/usr/lib/modules/", "/lib/modules/"]:
    let path = rootfs / (candidate & kernelVersion).strip(chars = {'/'})
    if dirExists(path): return path
  raise newException(IOError,
      "No module tree for kernel " & kernelVersion & " under " & rootfs)

proc loadModuleIndex*(rootfs, kernelVersion: string): ModuleIndex =
  result.root = findModuleRoot(rootfs, kernelVersion)
  let depPath = result.root / "modules.dep"
  if not fileExists(depPath):
    raise newException(IOError,
        "Missing modules.dep in " & result.root & "; run depmod for the target kernel")
  result.deps = parseModulesDep(readFile(depPath))
  for path in result.deps.keys:
    result.byName.mgetOrPut(path.extractFilename(), @[]).add path
  let builtinPath = result.root / "modules.builtin"
  if fileExists(builtinPath):
    result.builtin = parseModulesBuiltin(readFile(builtinPath))
    for path in result.builtin:
      result.builtinNames.incl path.extractFilename()

proc lookupByName*(index: ModuleIndex, name: string): seq[string] =
  ## Accept either a bare name ("erofs") or a filename ("erofs.ko").
  let fileName = if name.endsWith(".ko"): name else: name & ".ko"
  result = index.byName.getOrDefault(fileName, @[])
  result.sort()          # deterministic: prefer the lowest path

proc isBuiltin*(index: ModuleIndex, name: string): bool =
  ## True when the module is compiled into the kernel.
  ##
  ## A built-in module has no .ko, so it appears in modules.builtin and not in
  ## modules.dep. Checking the built-in list by basename first is therefore
  ## required: looking only at modules.dep paths would classify every built-in
  ## module as missing and fail the build.
  let fileName = if name.endsWith(".ko"): name else: name & ".ko"
  if fileName in index.builtinNames: return true
  # Fall back to the path-based test for a tree whose modules.builtin lists
  # entries we cannot match by basename.
  let paths = index.lookupByName(name)
  if paths.len == 0: return false
  for path in paths:
    if path notin index.builtin: return false
  true

proc collectModules*(index: ModuleIndex, names: seq[string]):
    tuple[files: seq[string], skippedBuiltin: seq[string], missing: seq[string]] =
  ## Resolve `names` and their dependencies to module paths relative to the
  ## module root. Built-in modules are reported separately, and names that are
  ## neither present nor built in are reported as missing rather than silently
  ## dropped.
  var seen = initHashSet[string]()
  var stack: seq[string]

  for name in names:
    if index.isBuiltin(name):
      result.skippedBuiltin.add name
      continue
    let paths = index.lookupByName(name)
    if paths.len == 0:
      # No .ko and not listed as built in: the kernel calls it something else or
      # the tree is incomplete. Report it rather than silently shipping a
      # rootfs the init cannot mount.
      if index.builtin.len == 0:
        result.skippedBuiltin.add name   # cannot tell; assume built in
      else:
        result.missing.add name
      continue
    stack.add paths[0]

  while stack.len > 0:
    let path = stack.pop()
    if path in seen: continue
    seen.incl path
    result.files.add path
    for dep in index.deps.getOrDefault(path, @[]):
      if dep notin seen: stack.add dep

  result.files.sort()


proc loadOrder*(index: ModuleIndex, files: seq[string]): seq[string] =
  ## Order `files` so that a module appears after everything it depends on.
  ## `finit_module` fails if a dependency is not loaded yet, and there is no
  ## modprobe or modules.dep inside the initramfs to sort this out at boot, so
  ## the order is computed here and shipped alongside the modules.
  ##
  ## Cycles are impossible in practice; if one appears, its members are emitted
  ## in path order rather than aborting the build.
  var state = initTable[string, int]()      # 0 = unvisited, 1 = visiting, 2 = done
  let wanted = files.toHashSet()

  proc visit(acc: var seq[string], path: string) =
    if state.getOrDefault(path, 0) != 0: return
    state[path] = 1
    for dep in index.deps.getOrDefault(path, @[]):
      if dep in wanted: visit(acc, dep)
    state[path] = 2
    acc.add path

  var remaining = files
  remaining.sort()
  for path in remaining:
    visit(result, path)

proc moduleFilePaths*(index: ModuleIndex, files: seq[string]): seq[string] =
  ## Absolute host paths for the selected modules, for copying.
  for f in files: result.add index.root / f
