## Initramfs compression.
##
## The kernel decompresses the archive with whatever decompressor it was built
## with; gzip is the only one universally available, zstd is smaller and modern
## kernels support it, and uncompressed is useful when debugging a boot failure
## because it removes a variable.
##
## Compression shells out to the system tool rather than linking a library: the
## build host is a Kreato system that already has gzip, and zstd is already a
## dependency of the image pipeline.

import std/[os, osproc, streams, strutils]

type
  Compression* = enum
    cmGzip = "gzip"
    cmZstd = "zstd"
    cmNone = "none"

proc parseCompression*(value: string): Compression =
  case value.toLowerAscii
  of "", "gzip", "gz": cmGzip
  of "zstd", "zst": cmZstd
  of "none": cmNone
  else:
    raise newException(ValueError,
        "Unknown initramfs compression '" & value & "' (use gzip, zstd or none)")

proc extension*(c: Compression): string =
  case c
  of cmGzip: ".gz"
  of cmZstd: ".zst"
  of cmNone: ""

proc commandFor*(c: Compression): seq[string] =
  ## The exact argv used to compress. `-n` for gzip keeps the timestamp out of
  ## the header so the same input produces the same bytes.
  case c
  of cmGzip: @["gzip", "-9", "-n", "-c"]
  of cmZstd: @["zstd", "-19", "-q", "-c"]
  of cmNone: @[]

proc requireTool*(c: Compression) =
  ## Fail early with a clear message rather than mid-build.
  if c == cmNone: return
  if findExe(commandFor(c)[0]).len == 0:
    raise newException(IOError,
        "Compression tool not found: " & commandFor(c)[0] &
        " (pass --compress none or install it)")

proc compress*(c: Compression, data: string): string =
  ## Compress `data`, returning the compressed bytes as a string.
  if c == cmNone: return data
  let argv = commandFor(c)
  let p = startProcess(argv[0], args = argv[1 .. ^1], options = {poUsePath})
  try:
    let input = p.inputStream
    let output = p.outputStream
    # Write in the same call as reading: both pipes are small, but a large input
    # would deadlock if we waited for exit before draining stdout.
    var reader = ""
    input.write(data)
    input.close()
    reader = output.readAll()
    let code = p.waitForExit()
    if code != 0:
      raise newException(IOError, argv[0] & " exited with " & $code)
    result = reader
  finally:
    p.close()
