import unittest
import os
import strutils
import posix
import std/typedthreads
import ../../kpkg/modules/libarchive

type
  ExtractTask = object
    archive: string
    destination: string
    expected: string
  ExtractResult = object
    ok: bool
    errorMsg: string

var resultChannel: Channel[ExtractResult]

proc extractWorker(task: ExtractTask) {.thread.} =
  {.cast(gcsafe).}:
    try:
      discard extract(task.archive, task.destination)
      let output = task.destination & "/payload.txt"
      resultChannel.send(ExtractResult(ok: fileExists(output) and
          readFile(output) == task.expected))
    except CatchableError:
      resultChannel.send(ExtractResult(ok: false,
          errorMsg: getCurrentExceptionMsg()))

suite "parallel libarchive extraction":
  test "independent handles extract concurrently without cwd changes":
    if not isAdmin():
      skip()
    let base = "/tmp/kpkg-archive-parallel-" & $getpid()
    let source = base & "/source"
    let archive = base & "/fixture.tar.gz"
    createDir(source)
    let expected = "parallel extraction payload\n".repeat(4096)
    writeFile(source & "/payload.txt", expected)
    createArchive(archive, source)

    const count = 8
    resultChannel.open(count + 2)
    var workers = newSeq[Thread[ExtractTask]](count)
    for i in 0 ..< count:
      let destination = base & "/dest-" & $i
      createDir(destination)
      createThread(workers[i], extractWorker,
          ExtractTask(archive: archive, destination: destination,
              expected: expected))

    for worker in workers.mitems:
      joinThread(worker)
    for _ in 0 ..< count:
      let res = resultChannel.recv()
      check res.ok
    resultChannel.close()

    check getCurrentDir() != source
    if dirExists(base):
      removeDir(base)
