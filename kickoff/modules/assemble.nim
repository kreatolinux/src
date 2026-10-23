## Assemble an initramfs from a rootfs tree.
##
## The archive contains exactly what the boot needs and nothing else:
##
##   /init                      the initramfs init
##   /lib64/...                 its interpreter and DT_NEEDED closure
##   /modules/<relative path>   selected kernel modules
##   /etc/kickoff/modules       load order, dependencies first
##   /etc/kickoff/rootfstype    fallback when the kernel command line is silent
##
## Modules are shipped in a private /modules tree rather than the usual
## /lib/modules/<version> because the init loads them by absolute path with
## finit_module, in the order computed at build time. That removes any need for
## modprobe, modules.dep or a module tree layout inside the archive.

import std/[algorithm, os, sets, strutils]

import ./[compress, cpio, libs, modules]

const
  moduleDir* = "/modules"
  configDir* = "/etc/kickoff"
  loadOrderPath* = configDir & "/modules"
  rootfsTypePath* = configDir & "/rootfstype"

type
  InitramfsOptions* = object
    rootfs*: string             ## rootfs tree to take modules and libraries from
    initBinary*: string         ## host path to the initramfs init
    kernelVersion*: string
    layout*: RootfsLayout
    compression*: Compression
    extraModules*: seq[string]  ## additional module names to include
    mtime*: uint32              ## archive timestamp, 0 for reproducible

  InitramfsResult* = object
    entries*: seq[CpioEntry]
    archive*: seq[byte]
    modules*: seq[string]       ## module paths, in load order
    libraries*: seq[string]     ## archive paths of the copied libraries
    skippedBuiltin*: seq[string]

proc rootfsTypeName(layout: RootfsLayout): string =
  ## The *layout* name, not the filesystem name: the init has to know that
  ## squashfs-iso needs an ISO mounted and a loop device, which rootfstype alone
  ## cannot express.
  $layout

proc parentDirs(path: string): seq[string] =
  ## Every ancestor of `path`, shallowest first, excluding ".".
  var parts = path.split('/')
  if parts.len > 0: parts.setLen(parts.len - 1)
  var current = ""
  for part in parts:
    if part.len == 0: continue
    current = if current.len == 0: part else: current & "/" & part
    result.add current

proc normalise(archivePath: string): string =
  ## Archive names are relative to the initramfs root. Callers naturally write
  ## absolute paths ("/etc/kickoff/modules"); strip the leading slash here rather
  ## than at every call site.
  archivePath.strip(chars = {'/'})

proc addFile(entries: var seq[CpioEntry], hostPath, archivePath: string,
             mtime: uint32) =
  if not fileExists(hostPath):
    raise newException(IOError, "missing file for initramfs: " & hostPath)
  let path = normalise(archivePath)
  # Evaluate the ancestor list once. Calling parentDirs() again inside the loop
  # header produced a spurious extra entry, and one call is clearer regardless.
  let parents = parentDirs(path)
  for dir in parents:
    entries.add CpioEntry(name: dir, kind: ckDir, permissions: 0o755'u32,
                          mtime: mtime)
  entries.add entryFromPath(hostPath, path, mtime)

proc addData(entries: var seq[CpioEntry], archivePath, data: string,
             mtime: uint32) =
  let path = normalise(archivePath)
  let parents = parentDirs(path)
  for dir in parents:
    entries.add CpioEntry(name: dir, kind: ckDir, permissions: 0o755'u32,
                          mtime: mtime)
  var entry = CpioEntry(name: path, kind: ckFile, permissions: 0o644'u32,
                        mtime: mtime)
  entry.data = newSeq[byte](data.len)
  for i, ch in data: entry.data[i] = byte(ch)
  entries.add entry

proc dedupeDirectories(entries: seq[CpioEntry]): seq[CpioEntry] =
  ## Several files can share a parent; keep the first directory entry per name.
  var seen = initHashSet[string]()
  for entry in entries:
    if entry.kind == ckDir:
      if entry.name in seen: continue
      seen.incl entry.name
    result.add entry

proc buildInitramfs*(options: InitramfsOptions): InitramfsResult =
  ## Resolve modules and libraries, then serialise the archive.
  if options.rootfs.len == 0:
    raise newException(ValueError, "rootfs is required")
  if options.initBinary.len == 0:
    raise newException(ValueError, "initBinary is required")
  if not fileExists(options.initBinary):
    raise newException(IOError, "initramfs init not found: " & options.initBinary)
  if options.kernelVersion.len == 0:
    raise newException(ValueError, "kernelVersion is required")

  let index = loadModuleIndex(options.rootfs, options.kernelVersion)
  var names = requiredModuleNames(options.layout)
  for extra in options.extraModules:
    if extra.len > 0 and extra notin names: names.add extra

  let collected = collectModules(index, names)
  if collected.missing.len > 0:
    raise newException(IOError,
        "Kernel modules not found and not built in: " & collected.missing.join(", ") &
        " (module tree: " & index.root & ")")
  result.skippedBuiltin = collected.skippedBuiltin
  result.modules = loadOrder(index, collected.files)

  let closure = libraryClosure(options.rootfs, @[options.initBinary])
  if closure.missing.len > 0:
    raise newException(IOError,
        "Shared libraries not found in the rootfs: " & closure.missing.join(", "))
  for copy in closure.copies:
    result.libraries.add copy.archivePath

  var entries: seq[CpioEntry]
  entries.add CpioEntry(name: ".", kind: ckDir, permissions: 0o755'u32,
                        mtime: options.mtime)

  entries.addFile(options.initBinary, "init", options.mtime)
  # /init must be executable; the source binary already is, but be explicit.
  entries[^1].permissions = 0o755'u32

  for copy in closure.copies:
    entries.addFile(copy.hostPath, copy.archivePath.strip(chars = {'/'}), options.mtime)

  for module in result.modules:
    entries.addFile(index.root / module, (moduleDir & "/" & module).strip(chars = {'/'}),
                    options.mtime)

  entries.addData(loadOrderPath, result.modules.join("\n") & (if result.modules.len > 0: "\n" else: ""),
                  options.mtime)
  entries.addData(rootfsTypePath, rootfsTypeName(options.layout) & "\n", options.mtime)

  result.entries = dedupeDirectories(entries)
  result.archive = buildArchive(result.entries)

proc writeInitramfs*(options: InitramfsOptions, outputPath: string): InitramfsResult =
  ## Build and write the (compressed) archive, returning what went into it.
  requireTool(options.compression)
  result = buildInitramfs(options)
  let packed = compress(options.compression, cast[string](result.archive))
  let parent = outputPath.parentDir
  if parent.len > 0: createDir(parent)
  writeFile(outputPath, packed)
