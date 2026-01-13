#[
  This module handles cache checking and early package installation
  for the builder.
  
  Extracted from buildcmd.nim to provide a clean interface for
  checking if a cached tarball exists and installing from it.
]#

import os
import ./types
import ../runparser
import ../lockfile
import ../commonPaths

proc checkCacheExists*(actualPackage: string, pkg: runFile,
                       kTarget: string): bool =
  ## Checks if a cached tarball exists for the package.
  ##
  ## Returns true if the tarball exists at the expected path.

  let tarballPath = kpkgArchivesDir & "/system/" & kTarget & "/" &
                    actualPackage & "-" & pkg.versionString & ".kpkg"
  return fileExists(tarballPath)

proc shouldInstallFromCache*(cache: CacheConfig, pkg: runFile): bool =
  ## Determines if the package should be installed from cache.
  ##
  ## Returns true if:
  ##   - Cache exists
  ##   - useCacheIfAvailable is true
  ##   - dontInstall is false
  ##   - Package is not in ignoreUseCacheIfAvailable list

  if not cache.useCacheIfAvailable:
    return false

  if cache.dontInstall:
    return false

  if cache.actualPackage in cache.ignoreUseCacheIfAvailable:
    return false

  return checkCacheExists(cache.actualPackage, pkg, cache.kTarget)

proc cleanupAfterCacheInstall*() =
  ## Cleans up build directories after installing from cache.

  removeDir(kpkgBuildRoot)
  removeDir(kpkgSrcDir)
  removeLockfile()
