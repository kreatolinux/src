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

import std/[os, osproc, sequtils, strutils, tempfiles]

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

proc compressFile*(c: Compression, source, destination: string) =
  ## Compress `source` into `destination`.
  ##
  ## The child's stdin and stdout are connected to files by the shell, not to
  ## pipes bridged from this process. Bridging two pipes from one thread
  ## deadlocks as soon as the child fills its stdout buffer while we are still
  ## writing stdin: gzip's buffer is 64 KiB and an initramfs carrying kernel
  ## modules is far larger than that, so the first real build hung until it was
  ## killed. File redirection has no such buffer to fill.
  if c == cmNone:
    copyFile(source, destination)
    return
  let argv = commandFor(c)
  var command = argv.map(quoteShell).join(" ")
  command.add " < " & quoteShell(source) & " > " & quoteShell(destination)
  let status = execCmd(command)
  if status != 0:
    raise newException(IOError,
        argv[0] & " exited with " & $status & " while compressing " & source)

proc compress*(c: Compression, data: string): string =
  ## Compress `data`, returning the compressed bytes. Convenience wrapper for
  ## callers that already hold the archive in memory and for tests; the build
  ## path uses compressFile to avoid a second copy.
  if c == cmNone: return data
  let directory = createTempDir("kickoff-compress-", "")
  try:
    let source = directory / "input"
    let destination = directory / "output"
    writeFile(source, data)
    compressFile(c, source, destination)
    result = readFile(destination)
  finally:
    removeDir(directory)
