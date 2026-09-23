## Exercise the CLI handlers in child processes with isolated lock/store paths.
import std/[unittest, os, osproc, strutils, streams]
import ../../../kpkg/commands/historycmd
import ../../../kpkg/modules/sqlite
import ../../../kpkg/modules/transactions/history

if paramCount() > 0:
  case paramStr(1)
  of "prepare": discard beginHistory(paramStr(2))
  of "status": historyStatus(paramStr(2))
  of "recover": historyRecover(paramStr(2), yes = paramCount() > 2)
  else: quit(2)
  quit(0)

proc invoke(action, root: string, input = "", yes = false): tuple[
    output: string, code: int] =
  var args = @[action, root]
  if yes: args.add("yes")
  let child = startProcess(getAppFilename(), args = args,
      options = {poStdErrToStdOut})
  defer: child.close()
  child.inputStream.write(input)
  child.inputStream.close()
  result.output = child.outputStream.readAll()
  result.code = child.waitForExit()

suite "history recovery CLI":
  test "status and empty recovery do not create root or lock":
    let root = getTempDir() / ("kpkg-history-cli-empty-" & $getCurrentProcessId())
    check not dirExists(root)
    let status = invoke("status", root)
    check status.code == 0
    check "No pending history recovery" in status.output
    let recovery = invoke("recover", root, yes = true)
    check recovery.code == 0
    check not dirExists(root)
    check not fileExists(lockfilePath)
    check not fileExists(lockfilePath & ".guard")

  test "status is read-only and declined recovery leaves stale lock untouched":
    let root = getTempDir() / ("kpkg-history-cli-pending-" &
        $getCurrentProcessId())
    check invoke("prepare", root).code == 0
    var pending: string
    for kind, path in walkDir(root / "var/lib/kpkg/history"):
      if kind == pcDir: pending = path
    check pending.len > 0
    let marker = readFile(pending / "pending.json")
    writeFile(lockfilePath, "2147483647")
    defer:
      removeDir(root)
      if fileExists(lockfilePath): removeFile(lockfilePath)
      if fileExists(lockfilePath & ".guard"): removeFile(lockfilePath & ".guard")
    let status = invoke("status", root)
    check status.code == 0
    check readFile(pending / "pending.json") == marker
    check readFile(lockfilePath) == "2147483647"
    check not fileExists(lockfilePath & ".guard")
    let declined = invoke("recover", root, input = "n\n")
    check declined.code == 0
    check "Cancelled." in declined.output
    check readFile(pending / "pending.json") == marker
    check readFile(lockfilePath) == "2147483647"
    check not fileExists(lockfilePath & ".guard")

  test "confirmed recovery retires an abandoned empty session":
    let root = getTempDir() / ("kpkg-history-cli-confirm-" &
        $getCurrentProcessId())
    check invoke("prepare", root).code == 0
    defer:
      removeDir(root)
      if fileExists(lockfilePath): removeFile(lockfilePath)
      if fileExists(lockfilePath & ".guard"): removeFile(lockfilePath & ".guard")
    let recovery = invoke("recover", root, yes = true)
    check recovery.code == 0
    check "History recovery complete:" in recovery.output
    check not fileExists(lockfilePath)
    let status = invoke("status", root)
    check status.code == 0
    check "No pending history recovery" in status.output
