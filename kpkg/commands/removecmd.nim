import ../modules/transactions/barrier
import os
import strutils
import ../modules/sqlite
import ../modules/config
import ../../common/logging
import ../modules/lockfile
import ../modules/processes
import ../modules/removeInternal
import ../modules/transactions/main
import ../modules/transactions/history
import ../modules/runparser
import ../modules/run3/run3

proc remove*(packages: seq[string], yes = false, root = "",
        force = false, autoRemove = false, configRemove = false,
                ignoreBasePackages = false): string =
  ## Remove packages.

  # bail early if user isn't admin
  if not isAdmin():
    error("you have to be root for this action.")
    quit(1)

  # Check for other instances before prompting user
  isKpkgRunning()
  createLockfile()
  defer: removeLockfile()
  assertNoAbandonedHistory(if root == "": "/" else: root)

  if packages.len == 0:
    error("please enter a package name")
    quit(1)

  var output: string
  var packagesFinal = packages

  if autoRemove:
    for package in packages:
      if not packageExists(package, root):
        error("package "&package&" is not installed")
        quit(1)
      packagesFinal = bloatDepends(package, root)&packagesFinal

  if not ignoreBasePackages:
    for package in packagesFinal:
      let basePackage = getPackage(package, root).basePackage
      if basePackage:
        error("\""&package&"\" is a part of base system, cannot remove")
        quit(1)

  for package in packagesFinal:
    let pkgRepo = findPkgRepo(package)
    let repoName = if not isEmptyOrWhitespace(pkgRepo): lastPathPart(
        pkgRepo) else: ""
    if isExcluded(package, repoName):
      warn "removing excluded package: " & package

  if not yes:
    echo "Removing: "&packagesFinal.join(" ")
    stdout.write "Do you want to continue? (y/N) "
    output = readLine(stdin)
  else:
    output = "y"

  if output.toLower() == "y":
    createLockfile()
    try:
      let session = beginHistory(root)
      var transactions: seq[Transaction]
      var reason = ""
      for i in packagesFinal:
        let tx = newTransaction(i, root)
        transactions.add(tx)
        let installed = root & "/var/cache/kpkg/installed/" & i
        for kind, candidate in walkDir(root & "/var/cache/kpkg/installed"):
          if candidate.startsWith(installed & "-"):
            reason = "init-specific package removal is not supported by rollback"
        if symlinkExists(installed):
          reason = "removal through a package alias is not supported by rollback"
        if fileExists(installed / "run3") or fileExists(installed / "run"):
          let parsed = runparser.parseRunfile(installed)
          if parsed.run3Data.parsed.hasFunction("postremove") or
              parsed.run3Data.parsed.hasFunction("postremove_" & i.replace('-', '_')):
            reason = "package hooks may change untracked files"
        markHistoryBarrier(root, reason)
        for path in getListFiles(i, root):
          let fullPath = root & "/" & path
          if symlinkExists(fullPath) or fileExists(fullPath):
            let backup = tx.backupFile(fullPath)
            tx.recordFileDeleted(fullPath, backup)
          elif dirExists(fullPath):
            tx.recordDirDeleted(fullPath)
        removeInternal(i, root, force = force, depCheck = true,
                fullPkgList = packages, removeConfigs = configRemove,
                runPostRemove = true, historyTx = tx)
        info("package "&i&" removed")
      finishHistory(session, transactions, reason)
      for tx in transactions: tx.commit()
    finally:
      removeLockfile()
    info("done")
    quit(0)

  info("exiting")
  quit(0)
