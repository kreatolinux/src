import os
import strutils
import ../modules/logger
import ../modules/commonPaths

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
        # Binary tarballs are stored in kpkgArchivesDir/system/{target}/{packagename}-{version}.kpkg
        # We need to search through all target directories
        var found = false
        let archivesSystemDir = kpkgArchivesDir & "/system"
        if dirExists(archivesSystemDir):
          for targetDir in walkDir(archivesSystemDir):
            if targetDir.kind == pcDir:
              for file in walkDir(targetDir.path):
                let filename = extractFilename(file.path)
                # Check if the filename starts with packagename-
                if filename.startsWith(packageName & "-") and filename.endsWith(".kpkg"):
                  removeFile(file.path)
                  found = true
                  debug("Removed binary: " & file.path)

          if found:
            info("Binary tarballs for package '" & packageName & "' removed from cache.")
          else:
            info("No binary tarballs found for package '" & packageName & "'.")
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
