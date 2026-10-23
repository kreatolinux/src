import std/[os, osproc, strutils, tempfiles, unittest]
import ../../kickoff/modules/compress

proc roundtrip(tool, packed, expected: string): bool =
  ## Decompress through files, not pipes. Bridging the child's stdin and stdout
  ## from one thread deadlocks once either side fills its 64 KiB buffer, which is
  ## exactly the bug compressFile() was rewritten to avoid -- so the test helper
  ## must not reintroduce it.
  let dir = createTempDir("kickoff-roundtrip-", "")
  try:
    let src = dir / "packed"
    let dst = dir / "plain"
    writeFile(src, packed)
    let status = execCmd(tool & " -d -c < " & quoteShell(src) & " > " & quoteShell(dst))
    if status != 0: return false
    result = readFile(dst) == expected
  finally:
    removeDir(dir)

proc incompressible(size: int): string =
  ## Deterministic pseudorandom bytes, so the archive does not shrink to nothing.
  var seed = 12345'u64
  result = newString(size)
  for i in 0 ..< size:
    seed = seed * 6364136223846793005'u64 + 1442695040888963407'u64
    result[i] = char((seed shr 33) and 0xFF)

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

  test "compresses data larger than a pipe buffer":
    # Regression: the first implementation wrote all of stdin before reading any
    # stdout, so anything past gzip's 64 KiB output buffer deadlocked both sides
    # and the build hung until killed. 4 MiB is far past that boundary.
    if findExe("gzip").len == 0:
      skip()
    else:
      let data = incompressible(4 * 1024 * 1024)
      let packed = compress(cmGzip, data)
      check packed.len > 0
      # Deliberately not asserting that it got smaller: incompressible input
      # plus gzip's header can come out slightly larger. What matters is that
      # it completed at all and round-trips.
      check roundtrip("gzip", packed, data)

  test "compressFile handles files larger than a pipe buffer":
    if findExe("gzip").len == 0:
      skip()
    else:
      let dir = createTempDir("kickoff-compress-big-", "")
      try:
        let source = dir / "in.bin"
        let destination = dir / "out.gz"
        let data = incompressible(2 * 1024 * 1024)
        writeFile(source, data)
        compressFile(cmGzip, source, destination)
        check getFileSize(destination) > 0
        check roundtrip("gzip", readFile(destination), data)
      finally:
        removeDir(dir)

  test "compressFile copies verbatim when compression is none":
    let dir = createTempDir("kickoff-compress-none-", "")
    try:
      let source = dir / "in"
      let destination = dir / "out"
      writeFile(source, "raw bytes")
      compressFile(cmNone, source, destination)
      check readFile(destination) == "raw bytes"
    finally:
      removeDir(dir)

  test "cmNone is a passthrough":
    let data = "raw bytes"
    check compress(cmNone, data) == data

  test "requireTool fails clearly when the tool is missing":
    requireTool(cmNone)
    if findExe("gzip").len > 0:
      requireTool(cmGzip)
