import std/[os, osproc, unittest, streams]
import ../../../kpkg/modules/lockfile
import ../../../kpkg/modules/sqlite

const dbRoot = "/tmp/kpkg-lock-nesting-db"

# Launch a fresh process, not fork with inherited in-memory lease counters.
if paramCount() == 1 and paramStr(1) == "probe":
  try:
    createLockfile()
    removeLockfile()
    quit(0)
  except IOError:
    quit(23)

if paramCount() == 1 and paramStr(1) in ["reader", "held-reader"]:
  try:
    discard databaseFingerprint(dbRoot)
    if paramStr(1) == "held-reader":
      echo "ready"
      stdout.flushFile()
      discard stdin.readLine()
    closeDb()
    quit(0)
  except IOError:
    quit(24)

proc workerLease() {.thread.} =
  {.cast(gcsafe).}:
    withLockfile:
      doAssert fileExists(lockfilePath)
      discard databaseFingerprint(dbRoot)

var workerReady: Channel[bool]
var workerFinish: Channel[bool]
proc heldWorkerLease() {.thread.} =
  {.cast(gcsafe).}:
    withLockfile:
      workerReady.send(true)
      discard workerFinish.recv()

proc contender(): int =
  execCmdEx(quoteShell(getAppFilename()) & " probe").exitCode

suite "mutation lock leases":
  test "nested scope keeps external exclusion until outer release":
    withLockfile:
      check contender() == 23
      withLockfile:
        check contender() == 23
      check fileExists(lockfilePath)
      check contender() == 23
    check not fileExists(lockfilePath)
    check contender() == 0

  test "exception unwinds inner lease without releasing outer":
    withLockfile:
      try:
        withLockfile:
          raise newException(IOError, "test unwind")
      except IOError:
        discard
      check contender() == 23
    check contender() == 0

  test "release without ownership does not delete another process marker":
    writeFile(lockfilePath, "test marker")
    removeLockfile()
    check readFile(lockfilePath) == "test marker"
    removeFile(lockfilePath)

  test "worker lease cannot release the coordinator lease":
    withLockfile:
      var worker: Thread[void]
      createThread(worker, workerLease)
      joinThread(worker)
      check contender() == 23
    check contender() == 0

  test "worker retains exclusion after coordinator releases":
    workerReady.open()
    workerFinish.open()
    var worker: Thread[void]
    withLockfile:
      createThread(worker, heldWorkerLease)
      discard workerReady.recv()
    check contender() == 23
    workerFinish.send(true)
    joinThread(worker)
    workerReady.close()
    workerFinish.close()
    check contender() == 0

  test "force clear refuses active ownership and clears only stale markers":
    withLockfile:
      expect IOError:
        forceClearLockfile()
      check contender() == 23
    writeFile(lockfilePath, "stale")
    forceClearLockfile()
    check not fileExists(lockfilePath)
    check contender() == 0

  test "exclusive mutation rejects a child live database open":
    withLockfile:
      check execCmdEx(quoteShell(getAppFilename()) & " reader").exitCode == 24
    check execCmdEx(quoteShell(getAppFilename()) & " reader").exitCode == 0

  test "child live database connection blocks mutation until close":
    let reader = startProcess(getAppFilename(), args = @["held-reader"],
        options = {poStdErrToStdOut})
    check reader.outputStream.readLine() == "ready"
    check contender() == 23
    reader.inputStream.writeLine("finish")
    reader.inputStream.flush()
    check reader.waitForExit() == 0
    reader.close()
    check contender() == 0

  test "own live read connection upgrades only after closing shared lease":
    discard databaseFingerprint(dbRoot)
    withLockfile:
      discard databaseFingerprint(dbRoot)
      check contender() == 23
    check contender() == 0

  test "exclusive acquisition migrates old guard permissions":
    setFilePermissions(lockfilePath & ".guard", {fpUserRead, fpUserWrite})
    withLockfile:
      check fpOthersRead in getFilePermissions(lockfilePath & ".guard")
      check fpGroupRead in getFilePermissions(lockfilePath & ".guard")
