import os
import ../modules/logger
import ../modules/commonPaths

proc clean*(sources = false, binaries = false, cache = false, environment = false) =
  ## Cleanup kpkg cache.
  if sources:
    removeDir(kpkgSourcesDir)
    success("Source tarballs removed from cache.")

  if binaries:
    removeDir(kpkgArchivesDir)
    success("Binary tarballs removed from cache.")

  if cache:
    removeDir(kpkgCacheDir&"/ccache")
    success("ccache directory removed.")
  
  if environment:
    removeDir(kpkgEnvPath)
    success("Build environment directory removed.")
    
  info("done", true)
