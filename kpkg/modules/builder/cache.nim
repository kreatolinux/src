#[
  This module handles cache checking and early package installation
  for the builder.
  
  Extracted from buildcmd.nim to provide a clean interface for
  checking if a cached tarball exists and installing from it.
]#

import os
import ./types
import ../runparser
import ../commonPaths

proc cacheArchivePath*(actualPackage: string, pkg: runFile,
                       kTarget: string, isBootstrap = false): string =
  ## Return the private archive path for this build kind. Bootstrap packages
  ## are cycle-breaking seeds and must never satisfy a normal cache lookup.
  let kind = if isBootstrap: "bootstrap" else: "system"
  kpkgArchivesDir & "/" & kind & "/" & kTarget & "/" &
      actualPackage & "-" & pkg.versionString & ".kpkg"

proc checkCacheExists*(actualPackage: string, pkg: runFile,
                       kTarget: string, isBootstrap = false): bool =
  ## Checks if a cached tarball exists for the requested build kind.
  fileExists(cacheArchivePath(actualPackage, pkg, kTarget, isBootstrap))

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

  return checkCacheExists(cache.actualPackage, pkg, cache.kTarget,
      cache.isBootstrap)

proc cleanupAfterCacheInstall*() =
  ## Cleans up build directories after installing from cache.

  removeDir(kpkgBuildRoot)
  removeDir(kpkgSrcDir)
