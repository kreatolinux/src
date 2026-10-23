## Shared-library closure for the initramfs.
##
## The initramfs init is a dynamically linked ELF binary, so the archive must
## carry its program interpreter and every DT_NEEDED object, at the paths the
## loader will look for. There is no ldconfig cache at that point, so the paths
## have to be correct by construction.
##
## Only 64-bit little-endian ELF is supported: both target architectures
## (aarch64, x86_64) are little-endian, and this runs against a Linux rootfs
## built by the same tree.

import std/[algorithm, os, sets, strutils]

const
  PT_LOAD* = 1'u32
  PT_DYNAMIC* = 2'u32
  PT_INTERP* = 3'u32
  DT_NULL* = 0'i64
  DT_NEEDED* = 1'i64
  DT_STRTAB* = 5'i64

type
  ElfError* = object of ValueError

  LoadSegment* = object
    offset*, vaddr*, filesz*: uint64

  ElfInfo* = object
    interpreter*: string          ## PT_INTERP, e.g. /lib/ld-linux-aarch64.so.1
    needed*: seq[string]          ## DT_NEEDED sonames, in declaration order

  LibCopy* = object
    hostPath*: string             ## where to read it from
    archivePath*: string          ## where to place it in the initramfs

proc u16(d: string, off: int): uint16 =
  if off + 2 > d.len: raise newException(ElfError, "truncated ELF header")
  uint16(ord(d[off])) or (uint16(ord(d[off + 1])) shl 8)

proc u32(d: string, off: int): uint32 =
  if off + 4 > d.len: raise newException(ElfError, "truncated ELF header")
  for i in 0 ..< 4: result = result or (uint32(ord(d[off + i])) shl (8 * i))

proc u64(d: string, off: int): uint64 =
  if off + 8 > d.len: raise newException(ElfError, "truncated ELF header")
  for i in 0 ..< 8: result = result or (uint64(ord(d[off + i])) shl (8 * i))

proc cstringAt(d: string, off: int): string =
  if off < 0 or off >= d.len: return ""
  var i = off
  while i < d.len and d[i] != '\0':
    result.add d[i]
    inc i

proc parseElf*(data: string): ElfInfo =
  ## Extract the interpreter and DT_NEEDED list from an ELF64 LE image.
  if data.len < 64 or data[0 .. 3] != "\x7fELF":
    raise newException(ElfError, "not an ELF file")
  if data[4] != '\x02':
    raise newException(ElfError, "only ELF64 is supported")
  if data[5] != '\x01':
    raise newException(ElfError, "only little-endian ELF is supported")

  let phoff = int(u64(data, 0x20))
  let phentsize = int(u16(data, 0x36))
  let phnum = int(u16(data, 0x38))
  if phentsize < 56: raise newException(ElfError, "unexpected program header size")

  var loads: seq[LoadSegment]
  var dynamicOffset = -1
  var dynamicSize = 0

  for i in 0 ..< phnum:
    let base = phoff + i * phentsize
    let pType = u32(data, base)
    let pOffset = u64(data, base + 8)
    let pVaddr = u64(data, base + 16)
    let pFilesz = u64(data, base + 32)
    case pType
    of PT_LOAD:
      loads.add LoadSegment(offset: pOffset, vaddr: pVaddr, filesz: pFilesz)
    of PT_DYNAMIC:
      dynamicOffset = int(pOffset)
      dynamicSize = int(pFilesz)
    of PT_INTERP:
      result.interpreter = cstringAt(data, int(pOffset))
    else:
      discard

  if dynamicOffset < 0: return           # statically linked: nothing to resolve

  proc vaddrToOffset(v: uint64): int =
    for seg in loads:
      if v >= seg.vaddr and v < seg.vaddr + seg.filesz:
        return int(seg.offset + (v - seg.vaddr))
    return -1

  # First pass: find DT_STRTAB, which is needed to read every DT_NEEDED name.
  var strtabAddr = high(uint64)
  var off = dynamicOffset
  while off + 16 <= dynamicOffset + dynamicSize:
    let tag = int64(u64(data, off))
    let value = u64(data, off + 8)
    if tag == DT_NULL: break
    if tag == DT_STRTAB: strtabAddr = value
    off += 16
  if strtabAddr == high(uint64): return
  let strtab = vaddrToOffset(strtabAddr)
  if strtab < 0: raise newException(ElfError, "cannot map DT_STRTAB into the file")

  # Second pass: collect DT_NEEDED names.
  off = dynamicOffset
  while off + 16 <= dynamicOffset + dynamicSize:
    let tag = int64(u64(data, off))
    let value = u64(data, off + 8)
    if tag == DT_NULL: break
    if tag == DT_NEEDED:
      let name = cstringAt(data, strtab + int(value))
      if name.len > 0: result.needed.add name
    off += 16

proc defaultSearchDirs*(): seq[string] =
  ## Where the dynamic loader looks for libraries on these targets. `/lib64`
  ## matters here: Kreato Linux installs its runtime objects there, and
  ## omitting it is exactly the mistake that broke booster.
  @["/lib64", "/usr/lib64", "/lib", "/usr/lib", "/usr/lib/aarch64-linux-gnu",
    "/lib/x86_64-linux-gnu", "/usr/lib/x86_64-linux-gnu"]

proc resolveSoname*(rootfs: string, soname: string,
                    searchDirs = defaultSearchDirs()): string =
  ## Find `soname` inside the rootfs, returning its archive path (absolute
  ## within the image). Empty when not found.
  for dir in searchDirs:
    let candidate = rootfs / (dir & "/" & soname).strip(chars = {'/'})
    if fileExists(candidate) or symlinkExists(candidate):
      return dir & "/" & soname
  ""

proc libraryClosure*(rootfs: string, binaries: seq[string],
                     searchDirs = defaultSearchDirs()):
    tuple[copies: seq[LibCopy], interpreter: string, missing: seq[string]] =
  ## Resolve the interpreter and the full DT_NEEDED closure for `binaries`.
  ## `binaries` are host paths; every library is placed in the image at the same
  ## absolute path the loader expects.
  var seen = initHashSet[string]()
  var queue: seq[string]

  for binary in binaries:
    let info = parseElf(readFile(binary))
    if info.interpreter.len > 0:
      result.interpreter = info.interpreter
      let host = rootfs / info.interpreter.strip(chars = {'/'})
      if fileExists(host) or symlinkExists(host):
        if info.interpreter notin seen:
          seen.incl info.interpreter
          result.copies.add LibCopy(hostPath: host, archivePath: info.interpreter)
      else:
        result.missing.add info.interpreter
    for soname in info.needed:
      queue.add soname

  while queue.len > 0:
    let soname = queue.pop()
    if soname in seen: continue
    let archivePath = resolveSoname(rootfs, soname, searchDirs)
    if archivePath.len == 0:
      result.missing.add soname
      continue
    seen.incl soname
    result.copies.add LibCopy(hostPath: rootfs / archivePath.strip(chars = {'/'}),
                              archivePath: archivePath)
    # Libraries can themselves depend on others; walk those too.
    let host = rootfs / archivePath.strip(chars = {'/'})
    try:
      for transitive in parseElf(readFile(host)).needed:
        if transitive notin seen: queue.add transitive
    except ElfError:
      discard   # not an ELF we can read; already reported by the caller's use

  result.copies.sort(proc (a, b: LibCopy): int = cmp(a.archivePath, b.archivePath))
