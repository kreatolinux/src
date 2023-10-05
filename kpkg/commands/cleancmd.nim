import os
import ../modules/logger

proc clean*(sources = false, binaries = false, cache = false) =
  ## Cleanup kpkg cache.
  if sources:
    removeDir("/var/cache/kpkg/sources")
    success("Source tarballs removed from cache.")

  if binaries:
    removeDir("/var/cache/kpkg/archives")
    success("Binary tarballs removed from cache.")

  if cache:
    removeDir("/var/cache/kpkg/ccache")
    success("ccache directory removed.")
    
  info("done", true)
