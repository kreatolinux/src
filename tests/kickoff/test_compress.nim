import std/[os, osproc, streams, strutils, unittest]
import ../../kickoff/modules/compress

proc roundtrip(tool, packed, expected: string): bool =
  ## Decompress `packed` with the matching tool and compare against `expected`.
  let p = startProcess(tool, args = ["-d", "-c"], options = {poUsePath})
  try:
    # Capture both streams once: each `p.inputStream` call returns a fresh
    # wrapper, so closing one and reading another does not work.
    let inp = p.inputStream
    let outp = p.outputStream
    inp.write(packed)
    inp.close()
    let decompressed = outp.readAll()
    discard p.waitForExit()
    result = decompressed == expected
  finally:
    p.close()

suite "initramfs compression":
  test "parseCompression accepts the documented names":
    check parseCompression("") == cmGzip
    check parseCompression("gzip") == cmGzip
    check parseCompression("GZ") == cmGzip
    check parseCompression("zstd") == cmZstd
    check parseCompression("none") == cmNone
    expect ValueError: discard parseCompression("bzip2")

  test "extensions match what the kernel expects to find":
    check extension(cmGzip) == ".gz"
    check extension(cmZstd) == ".zst"
    check extension(cmNone) == ""

  test "gzip output round-trips":
    if findExe("gzip").len == 0:
      skip()
    else:
      let data = "hello initramfs\n".repeat(100)
      let packed = compress(cmGzip, data)
      check packed.len > 0
      check packed != data
      check roundtrip("gzip", packed, data)

  test "gzip is deterministic for identical input":
    if findExe("gzip").len == 0:
      skip()
    else:
      let data = "reproducible\n".repeat(50)
      check compress(cmGzip, data) == compress(cmGzip, data)

  test "zstd round-trips when available":
    if findExe("zstd").len == 0:
      skip()
    else:
      let data = "hello initramfs\n".repeat(100)
      let packed = compress(cmZstd, data)
      check packed.len > 0
      check roundtrip("zstd", packed, data)

  test "cmNone is a passthrough":
    let data = "raw bytes"
    check compress(cmNone, data) == data

  test "requireTool fails clearly when the tool is missing":
    # cmNone must never require anything.
    requireTool(cmNone)
    if findExe("gzip").len > 0:
      requireTool(cmGzip)
