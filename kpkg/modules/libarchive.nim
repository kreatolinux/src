import os
import logger
import strutils
import sequtils

# libarchive bindings
{.passL: "-larchive".}

type
  structArchive* {.importc: "struct archive", header: "<archive.h>".} = object
  structArchiveEntry* {.importc: "struct archive_entry",
      header: "<archive_entry.h>".} = object

const
  ARCHIVE_EOF* = 1
  ARCHIVE_OK* = 0
  ARCHIVE_FAILED* = -25
  ARCHIVE_FATAL* = -30
  ARCHIVE_EXTRACT_TIME* = 0x0004
  ARCHIVE_EXTRACT_PERM* = 0x0002
  ARCHIVE_EXTRACT_ACL* = 0x0020
  ARCHIVE_EXTRACT_FFLAGS* = 0x0040
  ARCHIVE_EXTRACT_OWNER* = 0x0001

# LC_ALL varies by platform
when defined(macosx):
  const LC_ALL* = 0
else:
  const LC_ALL* = 6

# libc functions
proc setlocale*(category: cint, locale: cstring): cstring {.importc,
    header: "<locale.h>".}
proc chdir*(path: cstring): cint {.importc, header: "<unistd.h>".}

# Archive core
proc archiveReadNew*(): ptr structArchive {.importc: "archive_read_new",
    header: "<archive.h>".}
proc archiveWriteNew*(): ptr structArchive {.importc: "archive_write_new",
    header: "<archive.h>".}
proc archiveWriteDiskNew*(): ptr structArchive {.importc: "archive_write_disk_new",
    header: "<archive.h>".}
proc archiveReadDiskNew*(): ptr structArchive {.importc: "archive_read_disk_new",
    header: "<archive.h>".}

# Read operations
proc archiveReadSupportFormatAll*(a: ptr structArchive): cint {.importc: "archive_read_support_format_all",
    header: "<archive.h>".}
proc archiveReadSupportFilterAll*(a: ptr structArchive): cint {.importc: "archive_read_support_filter_all",
    header: "<archive.h>".}
proc archiveReadOpenFilename*(a: ptr structArchive, filename: cstring,
    blocksize: csize_t): cint {.importc: "archive_read_open_filename",
    header: "<archive.h>".}
proc archiveReadNextHeader*(a: ptr structArchive,
    entry: ptr ptr structArchiveEntry): cint {.importc: "archive_read_next_header",
    header: "<archive.h>".}
proc archiveReadNextHeader2*(a: ptr structArchive,
    entry: ptr structArchiveEntry): cint {.importc: "archive_read_next_header2",
    header: "<archive.h>".}
proc archiveReadDataBlock*(a: ptr structArchive, buff: pointer,
    size: ptr csize_t,
    offset: ptr int64): cint {.importc: "archive_read_data_block",
    header: "<archive.h>".}
proc archiveReadClose*(a: ptr structArchive): cint {.importc: "archive_read_close",
    header: "<archive.h>".}
proc archiveReadFree*(a: ptr structArchive): cint {.importc: "archive_read_free",
    header: "<archive.h>".}

# Read disk operations
proc archiveReadDiskSetStandardLookup*(a: ptr structArchive): cint {.importc: "archive_read_disk_set_standard_lookup",
    header: "<archive.h>".}
proc archiveReadDiskOpen*(a: ptr structArchive,
    path: cstring): cint {.importc: "archive_read_disk_open",
    header: "<archive.h>".}
proc archiveReadDiskDescend*(a: ptr structArchive): cint {.importc: "archive_read_disk_descend",
    header: "<archive.h>".}
proc archiveReadDiskSetSymlinkPhysical*(
  a: ptr structArchive): cint {.importc: "archive_read_disk_set_symlink_physical",
    header: "<archive.h>".}

# Write operations
proc archiveWriteDiskSetOptions*(a: ptr structArchive,
    flags: cint): cint {.importc: "archive_write_disk_set_options",
    header: "<archive.h>".}
proc archiveWriteDiskSetStandardLookup*(
  a: ptr structArchive): cint {.importc: "archive_write_disk_set_standard_lookup",
    header: "<archive.h>".}
proc archiveWriteOpenFilename*(a: ptr structArchive,
    filename: cstring): cint {.importc: "archive_write_open_filename",
    header: "<archive.h>".}
proc archiveWriteSetFormatFilterByExt*(a: ptr structArchive,
    filename: cstring): cint {.importc: "archive_write_set_format_filter_by_ext",
    header: "<archive.h>".}
proc archiveWriteSetFormatGnutar*(a: ptr structArchive): cint {.importc: "archive_write_set_format_gnutar",
    header: "<archive.h>".}
proc archiveWriteAddFilterGzip*(a: ptr structArchive): cint {.importc: "archive_write_add_filter_gzip",
    header: "<archive.h>".}
proc archiveWriteAddFilterXz*(a: ptr structArchive): cint {.importc: "archive_write_add_filter_xz",
    header: "<archive.h>".}
proc archiveWriteAddFilterZstd*(a: ptr structArchive): cint {.importc: "archive_write_add_filter_zstd",
    header: "<archive.h>".}
proc archiveWriteHeader*(a: ptr structArchive,
    entry: ptr structArchiveEntry): cint {.importc: "archive_write_header",
    header: "<archive.h>".}
proc archiveWriteData*(a: ptr structArchive, buff: pointer,
    len: csize_t): csize_t {.importc: "archive_write_data",
    header: "<archive.h>".}
proc archiveWriteDataBlock*(a: ptr structArchive, buff: pointer, size: csize_t,
    offset: int64): cint {.importc: "archive_write_data_block",
    header: "<archive.h>".}
proc archiveWriteFinishEntry*(a: ptr structArchive): cint {.importc: "archive_write_finish_entry",
    header: "<archive.h>".}
proc archiveWriteClose*(a: ptr structArchive): cint {.importc: "archive_write_close",
    header: "<archive.h>".}
proc archiveWriteFree*(a: ptr structArchive): cint {.importc: "archive_write_free",
    header: "<archive.h>".}

# libc getcwd for saving working directory
proc getcwd*(buf: cstring, size: csize_t): cstring {.importc, header: "<unistd.h>".}

# Entry operations
proc archiveEntryNew*(): ptr structArchiveEntry {.importc: "archive_entry_new",
    header: "<archive_entry.h>".}
proc archiveEntryFree*(entry: ptr structArchiveEntry) {.importc: "archive_entry_free",
    header: "<archive_entry.h>".}
proc archiveEntryPathname*(entry: ptr structArchiveEntry): cstring {.importc: "archive_entry_pathname",
    header: "<archive_entry.h>".}
proc archiveEntrySourcepath*(entry: ptr structArchiveEntry): cstring {.importc: "archive_entry_sourcepath",
    header: "<archive_entry.h>".}

# Error handling
proc archiveErrorString*(a: ptr structArchive): cstring {.importc: "archive_error_string",
    header: "<archive.h>".}

type
  LibarchiveError* = object of CatchableError

proc debugWarn(f: string, err: string) =
  when not defined(release):
    echo f&" failed: "&err

proc copyData(ar: ptr structArchive, aw: ptr structArchive): cint =
  # Function copy_data(), gotten from untar.c
  var r: cint
  var size: csize_t

  # Is a const in the original untar.c, but idk how to do immutable pointers, lmk if there is a way
  var buff: pointer

  var offset: int64
  while true:
    r = archiveReadDataBlock(ar, cast[pointer](addr(buff)), addr(size), addr(offset))
    if r == ARCHIVE_EOF:
      return ARCHIVE_OK
    if r != ARCHIVE_OK:
      return r
    r = archiveWriteDataBlock(aw, buff, size, offset)
    if r != ARCHIVE_OK:
      debugWarn("archiveWriteDataBlock()", $archiveErrorString(aw))
      return r

if setlocale(LC_ALL, "") == nil:
  raise newException(OSError, "setlocale failed")

proc extract*(fileName: string, path = getCurrentDir(), ignoreFiles = @[""],
    getFiles = @[""]): seq[string] =
  # Extracts a file to a directory.
  # Based on untar.c in libarchive/examples

  if not isAdmin():
    raise newException(OSError, "You need to be root to continue")

  if not dirExists(path):
    raise newException(OSError, '`'&path&"` doesn't exist")

  if not fileExists(fileName):
    raise newException(OSError, '`'&fileName&"` doesn't exist")

  var resultStr: seq[string]
  var a: ptr structArchive
  var ext: ptr structArchive
  var entry: ptr structArchiveEntry
  var r: cint

  a = archiveReadNew()
  ext = archiveWriteDiskNew()
  discard archiveWriteDiskSetOptions(ext, ARCHIVE_EXTRACT_TIME +
      ARCHIVE_EXTRACT_FFLAGS + ARCHIVE_EXTRACT_PERM + ARCHIVE_EXTRACT_ACL + ARCHIVE_EXTRACT_OWNER)
  discard archiveReadSupportFormatAll(a)
  discard archiveReadSupportFilterAll(a)
  discard archiveWriteDiskSetStandardLookup(ext)
  r = archiveReadOpenFilename(a, filename, 10240)

  # I am using chdir as compilation with setCurrentDir() fail for some reason.
  discard chdir(path)

  while true:
    r = archiveReadNextHeader(a, addr(entry))

    if r == ARCHIVE_EOF:
      break

    if r != ARCHIVE_OK:
      raise newException(LibarchiveError, $archiveErrorString(a))

    if not ($archiveEntryPathname(entry) in resultStr):
      resultStr = resultStr&($archiveEntryPathname(entry))

    if not (isEmptyOrWhitespace(getFiles.join(""))) and not (
        $archiveEntryPathname(entry) in getFiles):
      continue

    if $archiveEntryPathname(entry) in ignoreFiles and fileExists(path&"/"&(
        $archiveEntryPathname(entry))):
      debug($archiveEntryPathname(entry)&" in ignoreFiles, ignoring")
      continue

    r = archiveWriteHeader(ext, entry)
    if r != ARCHIVE_OK:
      debugWarn("archiveWriteHeader()", $archiveErrorString(ext))
    discard copyData(a, ext)
    r = archiveWriteFinishEntry(ext)
    if r != ARCHIVE_OK:
      raise newException(LibarchiveError, $archiveErrorString(ext))

  discard archiveReadClose(a)
  discard archiveReadFree(a)
  discard archiveWriteClose(ext)
  discard archiveWriteFree(ext)
  return resultStr

proc createArchive*(fileName: string, path = getCurrentDir(), format = "auto",
    filter = "gzip") =
  ## Creates an archive from the contents of a directory.
  ## Based on minitar.c
  ##
  ## Parameters:
  ##   fileName: Output archive path
  ##   path: Directory to archive (contents will be archived, not the directory itself)
  ##   format: Archive format - "auto" (detect from extension), "gnutar"
  ##   filter: Compression filter - "gzip" (default), "xz", "zstd", "auto" (detect from extension)

  if not dirExists(path):
    raise newException(OSError, '`'&path&"` doesn't exist")

  var archive: ptr structArchive
  var entry: ptr structArchiveEntry
  var r: cint
  var file: File
  var length: csize_t
  var buffer: pointer = alloc(16384)

  # Save current working directory
  var savedCwd: array[4096, char]
  if getcwd(cast[cstring](addr savedCwd[0]), 4096) == nil:
    dealloc(buffer)
    raise newException(OSError, "Failed to get current working directory")

  archive = archiveWriteNew()

  try:
    # Set format and filter
    if format == "auto" and filter == "auto":
      # Detect both from extension
      if archiveWriteSetFormatFilterByExt(archive, fileName) != ARCHIVE_OK:
        raise newException(LibarchiveError, "Couldn't guess file format by extension")
    else:
      # Set format
      if format == "auto" or format == "gnutar":
        if archiveWriteSetFormatGnutar(archive) != ARCHIVE_OK:
          raise newException(LibarchiveError, "Failed to set gnutar format")
      else:
        raise newException(LibarchiveError, "Unsupported format: " & format)

      # Set filter
      case filter
      of "gzip":
        if archiveWriteAddFilterGzip(archive) != ARCHIVE_OK:
          raise newException(LibarchiveError, "Failed to add gzip filter")
      of "xz":
        if archiveWriteAddFilterXz(archive) != ARCHIVE_OK:
          raise newException(LibarchiveError, "Failed to add xz filter")
      of "zstd":
        if archiveWriteAddFilterZstd(archive) != ARCHIVE_OK:
          raise newException(LibarchiveError, "Failed to add zstd filter")
      else:
        raise newException(LibarchiveError, "Unsupported filter: " & filter)

    if archiveWriteOpenFilename(archive, filename) != ARCHIVE_OK:
      raise newException(LibarchiveError, "Failed to open archive for writing: " &
          $archiveErrorString(archive))

    discard chdir(path)

    for i in toSeq(walkDirRec(path, {pcFile, pcLinkToFile, pcDir, pcLinkToDir})):

      var disk = archiveReadDiskNew()

      discard archiveReadDiskSetStandardLookup(disk)

      r = archiveReadDiskOpen(disk, cstring(relativePath(i, getCurrentDir())))

      if r != ARCHIVE_OK:
        discard archiveReadFree(disk)
        raise newException(LibarchiveError, $archiveErrorString(disk))

      discard archiveReadDiskSetSymlinkPhysical(disk)

      while true:
        entry = archiveEntryNew()
        r = archiveReadNextHeader2(disk, entry)

        if r == ARCHIVE_EOF:
          archiveEntryFree(entry)
          break

        if r != ARCHIVE_OK:
          archiveEntryFree(entry)
          discard archiveReadClose(disk)
          discard archiveReadFree(disk)
          raise newException(LibarchiveError, $archiveErrorString(disk))

        discard archiveReadDiskDescend(disk)

        r = archiveWriteHeader(archive, entry)

        if r == ARCHIVE_FATAL:
          archiveEntryFree(entry)
          discard archiveReadClose(disk)
          discard archiveReadFree(disk)
          raise newException(LibarchiveError, "Fatal error writing archive header: " &
              $archiveErrorString(archive))

        if r < ARCHIVE_OK:
          debugWarn("archiveWriteHeader", $archiveErrorString(archive))

        if r > ARCHIVE_FAILED and fileExists(i):
          file = open($archiveEntrySourcepath(entry))
          length = csize_t(readBuffer(file, buffer, sizeof(buffer)))
          while length > 0:
            discard archiveWriteData(archive, buffer, length)
            length = csize_t(readBuffer(file, buffer, sizeof(buffer)))
          close(file)
        archiveEntryFree(entry)
      discard archiveReadClose(disk)
      discard archiveReadFree(disk)

  finally:
    discard archiveWriteClose(archive)
    discard archiveWriteFree(archive)
    dealloc(buffer)
    # Restore working directory
    discard chdir(cast[cstring](addr savedCwd[0]))
