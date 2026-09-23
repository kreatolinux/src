import unittest
import std/typedthreads
import os
import posix
import ../../../kpkg/modules/runparser

var parserPath: string

proc parserWorker() {.thread.} =
  {.cast(gcsafe).}:
    for _ in 0 ..< 100:
      let parsed = parseRunfile(parserPath)
      doAssert parsed.versionString == "1.0-1"

suite "thread-safe runfile parsing":
  test "ORC serializes parser and substitution state":
    parserPath = "/tmp/kpkg-runparser-thread-" & $getpid()
    createDir(parserPath)
    writeFile(parserPath & "/run3", """
name: "thread-parser"
version: "1.0"
release: "1"
depends:
  - "dep-${version}"
""")
    var workers: array[4, Thread[void]]
    for worker in workers.mitems:
      createThread(worker, parserWorker)
    for worker in workers.mitems:
      joinThread(worker)
    removeDir(parserPath)
