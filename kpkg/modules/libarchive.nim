import os
import sequtils
import futhark

importc:
  path "/usr/include"
  "archive.h"
  "archive_entry.h"
  "unistd.h"

type
  LibarchiveError* = object of CatchableError 

proc debugWarn(f: string, err: string) =
  when not defined(release):
    echo f&" failed: "&err

proc copyData(ar: ptr structarchive, aw: ptr structarchive): int =
  # Function copy_data(), gotten from untar.c
  var r: int
  var size: culong 
  
  # Is a const in the original untar.c, but idk how to do immutable pointers, lmk if there is a way
  var buff: pointer 
  
  var offset: clong
  while true:
    r = archiveReadDataBlock(ar, addr(buff), addr(size), addr(offset))
    if r == ARCHIVE_EOF:
      return ARCHIVE_OK
    if r != ARCHIVE_OK:
      return r
    r = archiveWriteDataBlock(aw, buff, size, offset)
    if r != ARCHIVE_OK:
      debugWarn("archive_write_data_block()", $archive_error_string(aw))
      return r

proc extract*(fileName: string, path = getCurrentDir()): seq[string] =
  # Extracts a file to a directory.
  # Based on untar.c in libarchive/examples

  if not isAdmin():
    raise newException(OSError, "You need to be root to continue")

  if not dirExists(path):
    raise newException(OSError, '`'&path&"` doesn't exist")
  
  if not fileExists(fileName):
    raise newException(OSError, '`'&fileName&"` doesn't exist")

  var resultStr: seq[string]
  var a: ptr structarchive
  var ext: ptr structarchive
  var entry: ptr structarchiveentry
  var r: int

  a = archiveReadNew()
  ext = archiveWriteDiskNew()
  discard archiveWriteDiskSetOptions(ext, ARCHIVE_EXTRACT_TIME + ARCHIVE_EXTRACT_FFLAGS + ARCHIVE_EXTRACT_PERM + ARCHIVE_EXTRACT_ACL + ARCHIVE_EXTRACT_OWNER)
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
    
    r = archiveWriteHeader(ext, entry)
    if r != ARCHIVE_OK:
      debugWarn("archive_write_header()", $archiveErrorString(ext))
    discard copy_data(a, ext)
    r = archive_write_finish_entry(ext)
    if r != ARCHIVE_OK:
      raise newException(LibarchiveError, $archiveErrorString(ext))

  discard archiveReadClose(a)
  discard archiveReadFree(a)
  discard archiveWriteClose(ext)
  discard archiveWriteFree(ext)
  return resultStr

proc createArchive*(fileName: string, path = getCurrentDir()) =
  # Creates an archive in the desired directory.
  # Based on minitar.c
  
  if not dirExists(path):
    raise newException(OSError, '`'&path&"` doesn't exist")

  var archive: ptr structarchive
  var entry: ptr structarchiveentry
  var r: int
  var file: File
  var length: culong
  var buffer: pointer = alloc(16384)

  archive = archiveWriteNew()
  
  if archive_write_set_format_filter_by_ext(archive, fileName) != ARCHIVE_OK:
    raise newException(OSError, "Couldn't guess file format by extension")

  discard archive_write_open_filename(archive, filename)

  discard chdir(path)

  for i in toSeq(walkDirRec(path, {pcFile, pcLinkToFile, pcDir, pcLinkToDir})):
    
    var disk = archive_read_disk_new()
    
    discard archive_read_disk_set_standard_lookup(disk)
    
    r = archive_read_disk_open(disk, cstring(relativePath(i, getCurrentDir())))
    
    if r != ARCHIVE_OK:
      raise newException(LibarchiveError, $archive_error_string(disk))
    
    discard archive_read_disk_set_symlink_physical(disk)
    
    while true:
      entry = archive_entry_new()
      r = archive_read_next_header2(disk, entry)
      
      if r == ARCHIVE_EOF:
        break
      
      if r != ARCHIVE_OK:
        raise newException(LibarchiveError, $archive_error_string(disk))
      
      discard archive_read_disk_descend(disk)
      
      r = archive_write_header(archive, entry)
      
      if r < ARCHIVE_OK:
        debugWarn("", $archive_error_string(archive))
      
      if r == ARCHIVE_FATAL:
        quit(1)
      
      if r > ARCHIVE_FAILED and fileExists(i):
        file = open($archive_entry_sourcepath(entry))
        length = culong(readBuffer(file, buffer, sizeof(buffer)))
        while length > 0:
          discard archive_write_data(archive, buffer, length)
          length = culong(readBuffer(file, buffer, sizeof(buffer)))
      archive_entry_free(entry)
    discard archive_read_close(disk)
    discard archive_read_free(disk)
  discard archive_write_close(archive)
  discard archive_write_free(archive)
