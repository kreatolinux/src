import os
import strutils
import ../../common/logging
import ../modules/commonPaths

proc cleanPackageBinaries(packageName: string): bool =
  ## Remove all binary tarballs for a package across all targets.
  ## Returns true if any files were removed.
  result = false
  let archivesSystemDir = kpkgArchivesDir & "/system"
  if not dirExists(archivesSystemDir):
    return false

  for targetDir in walkDir(archivesSystemDir):
    if targetDir.kind != pcDir:
      continue
    for file in walkDir(targetDir.path):
      let filename = extractFilename(file.path)
      if filename.startsWith(packageName & "-") and filename.endsWith(".kpkg"):
        removeFile(file.path)
        result = true
        debug("Removed binary: " & file.path)

proc clean*(packages: seq[string] = @[], sources = false, binaries = false,
    cache = false, environment = false) =
  ## Cleanup kpkg cache.

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
