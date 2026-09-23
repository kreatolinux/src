import os
import strutils
import ../../common/logging
import ../modules/commonPaths
import ../modules/transactions/history
import ../modules/lockfile
import ../modules/processes
import ../modules/gitutils

proc cleanPackageBinaries(packageName: string): bool =
  ## Remove all binary tarballs for a package across all targets.
  ## Returns true if any files were removed.
  result = false
  for kind in ["system", "bootstrap"]:
    let archivesKindDir = kpkgArchivesDir & "/" & kind
    if not dirExists(archivesKindDir):
      continue

    for targetDir in walkDir(archivesKindDir):
      if targetDir.kind != pcDir:
        continue
      for file in walkDir(targetDir.path):
        let filename = extractFilename(file.path)
        if filename.startsWith(packageName & "-") and filename.endsWith(".kpkg"):
          removeFile(file.path)
          result = true
          debug("Removed binary: " & file.path)

proc clean*(packages: seq[string] = @[], sources = false, binaries = false,
    cache = false, environment = false, transactions = -1,
    root = "/", yes = false, clearLock = false) =
  ## Clean cached files, old transactions, or a stale lock.

  if transactions < -1: fatal("transactions must be a nonnegative age in days (-1 disables cleanup)")
  if transactions >= 0 or clearLock:
    if not isAdmin(): fatal("you have to be root for this action.")
    if packages.len > 0:
      fatal("package names cannot be combined with --transactions or --clear-lock")
    # Resolve root before isKpkgRunning changes the working directory.
    let targetRoot = normalizedPath(absolutePath(if root.len ==
        0: "/" else: root))
    isKpkgRunning()
    if clearLock:
      # Do not bypass a live owner's lock; stale locks are removed here.
      checkLockfile()
      discard recoverFromCommitBuild()
      forceClearLockfile()
    if transactions >= 0:
      checkLockfile()
      if not yes:
        echo "Permanently remove transactions older than " & $transactions &
            " days and their rollback backups for " & targetRoot & "?"
        stdout.write "Continue? (y/N) "
        if stdin.readLine().strip().toLowerAscii() notin ["y", "yes"]:
          info("cancelled")
          return
      checkLockfile()
      createLockfile()
      var failure = ""
      try:
        let removed = cleanHistory(targetRoot, transactions)
        info("Removed " & $removed & " old transaction(s) and their rollback backups.")
      except CatchableError as e:
        failure = e.msg
      finally:
        removeLockfile()
        clearErrorCallback()
      if failure.len > 0: fatal("clean: " & failure)


  # If package name is provided, only clean that package's cache
  if packages.len > 0:
    for packageName in packages:
      if sources:
        let pkgSourcesDir = kpkgSourcesDir & "/" & packageName
        if dirExists(pkgSourcesDir):
          removeDir(pkgSourcesDir)
          info("Source tarballs for package '" & packageName & "' removed from cache.")
        else:
          info("No source tarballs found for package '" & packageName & "'.")

      if binaries:
        if cleanPackageBinaries(packageName):
          info("Binary tarballs for package '" & packageName & "' removed from cache.")
        else:
          info("No binary tarballs found for package '" & packageName & "'.")

    info("done")
    quit(0)

  # If no package specified, clean everything (original behavior)
  if sources:
    removeDir(kpkgSourcesDir)
    info("Source tarballs removed from cache.")

  if binaries:
    removeDir(kpkgArchivesDir)
    info("Binary tarballs removed from cache.")

  if cache:
    removeDir(kpkgCacheDir&"/ccache")
    info("ccache directory removed.")

  if environment:
    removeDir(kpkgEnvPath)
    info("Build environment directory removed.")

  info("done")
  quit(0)
