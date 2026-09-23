import unittest
import std/typedthreads
import ../../../common/logging

proc loggingWorker() {.thread.} =
  {.cast(gcsafe).}:
    for i in 0 ..< 200:
      debug "worker message " & $i

suite "thread-local logging":
  test "ORC workers can log concurrently":
    initLogger("logging-test", "", "/tmp/logging-test.log")
    var workers: array[4, Thread[void]]
    for worker in workers.mitems:
      createThread(worker, loggingWorker)
    for worker in workers.mitems:
      joinThread(worker)
    check true
