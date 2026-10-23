## cpio "newc" archive writer.
##
## The initramfs format is a cpio archive in the `newc` (SVR4, "070701") variant,
## optionally compressed. The format is a flat sequence of entries:
##
##   "070701" + 13 fields of 8 ASCII hex digits + NUL-terminated name
##   name padded to 4 bytes, file data padded to 4 bytes
##
## terminated by an entry named `TRAILER!!!` with no data. Every field is a
## 32-bit unsigned value written as 8 lowercase hex digits, so there is no
## endianness involved and the archive can be produced on any host.
##
## This module does not shell out to `cpio`; it writes the bytes directly. That
## keeps generation deterministic (fixed inode/mtime handling, stable ordering)
## and makes it testable without external tools.

import std/[algorithm, os, posix, strutils]

const
  newcMagic* = "070701"
  newcHeaderLen* = 110        ## 6 magic + 13 * 8
  newcAlign* = 4
  newcTrailer* = "TRAILER!!!"

  # st_mode file-type bits, from sys/stat.h
  S_IFREG* = 0o100000'u32
  S_IFDIR* = 0o040000'u32
  S_IFLNK* = 0o120000'u32
  S_IFCHR* = 0o020000'u32
  S_IFBLK* = 0o060000'u32
  S_IFIFO* = 0o010000'u32

type
  CpioEntryKind* = enum
    ckFile = "regular file"
    ckDir = "directory"
    ckSymlink = "symlink"
    ckCharDev = "character device"
    ckBlockDev = "block device"
    ckFifo = "fifo"

  CpioEntry* = object
    name*: string             ## archive path, relative, no leading "/"
    kind*: CpioEntryKind
    permissions*: uint32      ## 12 permission bits, filesystem type added on write
    data*: seq[byte]          ## file contents, or the link target for symlinks
    mtime*: uint32
    uid*, gid*: uint32
    devMajor*, devMinor*: uint32    ## device holding the inode (irrelevant for initramfs)
    rdevMajor*, rdevMinor*: uint32  ## device node numbers, used for ckCharDev/ckBlockDev

proc typeBits(kind: CpioEntryKind): uint32 =
  case kind
  of ckFile: S_IFREG
  of ckDir: S_IFDIR
  of ckSymlink: S_IFLNK
  of ckCharDev: S_IFCHR
  of ckBlockDev: S_IFBLK
  of ckFifo: S_IFIFO

proc pad4(n: int): int =
  ## Bytes of padding needed to reach a 4-byte boundary.
  (newcAlign - (n mod newcAlign)) mod newcAlign

proc hex8(value: uint32): string =
  ## 8 lowercase hex digits, as newc requires.
  result = newString(8)
  const digits = "0123456789abcdef"
  for i in 0 ..< 8:
    result[7 - i] = digits[int((value shr (i * 4)) and 0xF'u32)]

proc validateName(name: string) =
  if name.len == 0:
    raise newException(ValueError, "cpio entry name must not be empty")
  if name[0] == '/':
    raise newException(ValueError,
        "cpio entry name must be relative (initramfs paths are mounted at /): " & name)
  for part in name.split('/'):
    if part == "..":
      raise newException(ValueError, "cpio entry name must not contain '..': " & name)

proc header(entry: CpioEntry, inode: uint32, linkCount: uint32): string =
  ## The 110-byte header plus the NUL-terminated name, unpadded.
  let nameLen = entry.name.len + 1          # namesize includes the NUL
  let mode = typeBits(entry.kind) or (entry.permissions and 0o7777'u32)
  let fileSize = if entry.kind in {ckFile, ckSymlink}: uint32(entry.data.len) else: 0'u32
  result = newcMagic
  result.add hex8(inode)
  result.add hex8(mode)
  result.add hex8(entry.uid)
  result.add hex8(entry.gid)
  result.add hex8(linkCount)
  result.add hex8(entry.mtime)
  result.add hex8(fileSize)
  result.add hex8(entry.devMajor)
  result.add hex8(entry.devMinor)
  result.add hex8(entry.rdevMajor)
  result.add hex8(entry.rdevMinor)
  result.add hex8(uint32(nameLen))
  result.add hex8(0'u32)                    # check, unused
  result.add entry.name
  result.add '\0'

proc writeEntry(outp: var seq[byte], entry: CpioEntry, inode: uint32,
                linkCount: uint32) =
  let hdr = header(entry, inode, linkCount)
  for ch in hdr: outp.add byte(ch)
  for _ in 0 ..< pad4(hdr.len): outp.add 0'u8
  # Only regular files and symlinks carry data; directories and device nodes
  # must not, or the kernel rejects the archive.
  if entry.kind in {ckFile, ckSymlink}:
    outp.add entry.data
    for _ in 0 ..< pad4(entry.data.len): outp.add 0'u8

proc sortedEntries(entries: seq[CpioEntry]): seq[CpioEntry] =
  ## Deterministic order: shallower paths first so parents precede children, then
  ## lexicographic. The kernel does not require this, but a stable order makes
  ## archives reproducible and diffs meaningful.
  result = entries
  result.sort(proc (a, b: CpioEntry): int =
    let ad = a.name.count('/')
    let bd = b.name.count('/')
    if ad != bd: return cmp(ad, bd)
    cmp(a.name, b.name))

proc buildArchive*(entries: seq[CpioEntry]): seq[byte] =
  ## Serialise entries into a complete newc archive, including the trailer.
  var inode = 1'u32
  for entry in sortedEntries(entries):
    validateName(entry.name)
    # newc carries no hardlink table here: every entry gets its own inode and a
    # link count of one. Directories conventionally use 2.
    let links = if entry.kind == ckDir: 2'u32 else: 1'u32
    result.writeEntry(entry, inode, links)
    inc inode
  # Trailer: an entry with no data, which ends the archive.
  var trailer = CpioEntry(name: newcTrailer, kind: ckFile)
  result.writeEntry(trailer, inode, 1)


proc rdevMajor(dev: uint64): uint32 =
  ## glibc's major(3) encoding for Linux dev_t. Not a portable abstraction; the
  ## initramfs is a Linux artefact and the host that builds it is Linux.
  uint32(((dev shr 8) and 0xfff'u64) or ((dev shr 32) and not 0xfff'u64))

proc rdevMinor(dev: uint64): uint32 =
  uint32((dev and 0xff'u64) or ((dev shr 12) and not 0xff'u64))

proc lstatOf(path: string): Stat =
  ## lstat(2), not stat(2): a symlink must be archived as a symlink, and a
  ## dangling one must not be an error.
  if posix.lstat(path.cstring, result) != 0:
    raise newException(IOError, "cannot lstat " & path & ": " & $strerror(errno))


proc sourceDateEpoch*(): uint32 =
  ## Reproducible-builds timestamp. Honouring SOURCE_DATE_EPOCH keeps archive
  ## bytes stable across runs; without it every entry would carry its own mtime
  ## and two builds of the same tree would differ.
  let raw = getEnv("SOURCE_DATE_EPOCH")
  if raw.len == 0: return 0'u32
  try:
    let value = parseBiggestInt(raw)
    if value <= 0 or value > int64(high(uint32)): return 0'u32
    uint32(value)
  except ValueError:
    return 0'u32

proc entryFromPath*(path, name: string, mtime = 0'u32): CpioEntry =
  ## Build an entry from a filesystem object. `name` is the archive path.
  ## The numeric st_mode is used rather than Nim's FilePermission set, because
  ## the device-node and fifo bits have no FilePermission equivalent.
  let st = lstatOf(path)
  result.name = name
  result.mtime = if mtime != 0: mtime else: uint32(st.st_mtim.tv_sec)
  result.uid = 0
  result.gid = 0
  result.permissions = uint32(st.st_mode) and 0o7777'u32
  let ifmt = uint32(st.st_mode) and 0o170000'u32
  case ifmt
  of S_IFREG:
    result.kind = ckFile
    let size = int(st.st_size)
    result.data = newSeq[byte](size)
    if size > 0:
      let f = open(path, fmRead)
      try:
        let n = f.readBuffer(addr result.data[0], size)
        result.data.setLen(n)
      finally:
        f.close()
  of S_IFDIR:
    result.kind = ckDir
  of S_IFLNK:
    result.kind = ckSymlink
    let target = expandSymlink(path)
    result.data = newSeq[byte](target.len)
    for i, ch in target: result.data[i] = byte(ch)
  of S_IFCHR:
    result.kind = ckCharDev
    result.rdevMajor = rdevMajor(uint64(st.st_rdev))
    result.rdevMinor = rdevMinor(uint64(st.st_rdev))
  of S_IFBLK:
    result.kind = ckBlockDev
    result.rdevMajor = rdevMajor(uint64(st.st_rdev))
    result.rdevMinor = rdevMinor(uint64(st.st_rdev))
  of S_IFIFO:
    result.kind = ckFifo
  else:
    raise newException(ValueError, "unsupported file type for initramfs: " & path)

proc walkInto(acc: var seq[CpioEntry], dir, archDir: string) =
  ## Recursive helper for scanTree. Takes the accumulator by `var` rather than
  ## capturing a `result` seq in a closure, which Nim forbids for memory safety.
  for kind, child in walkDir(dir, relative = false):
    let base = child.extractFilename()
    let archPath = if archDir == "." or archDir.len == 0: base else: archDir & "/" & base
    if kind == pcDir:
      acc.add CpioEntry(name: archPath, kind: ckDir, permissions: 0o755'u32)
      walkInto(acc, child, archPath)
    else:
      acc.add entryFromPath(child, archPath)

proc scanTree*(root: string, prefix = ""): seq[CpioEntry] =
  ## Walk `root` and return one entry per object, including directories.
  ## Symlinks are stored as symlinks, never followed.
  if not dirExists(root):
    raise newException(IOError, "not a directory: " & root)
  let top = if prefix.len > 0: prefix else: "."
  result.add CpioEntry(name: top, kind: ckDir, permissions: 0o755'u32)
  walkInto(result, root, top)
