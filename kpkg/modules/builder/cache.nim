#[
  This module handles cache checking and early package installation
  for the builder.
  
  Extracted from buildcmd.nim to provide a clean interface for
  checking if a cached tarball exists and installing from it.
]#

import os
import strutils
import ./types
import ../runparser
import ../commonPaths
import ../config
import ../checksums
import ../downloader
import ../../../common/logging

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

proc seedBinaryArchive*(pkg: runFile, kTarget: string): bool =
  ## Populate the local archive cache for `pkg` from a binary repository.
  ##
  ## `build` normally only consults the local archive cache, so every
  ## dependency is compiled from source even when a matching binary exists on
  ## a mirror. With --binCache we fetch those binaries up front: the existing
  ## cache-hit path in builderImpl() then installs them instead of rebuilding.
  ##
  ## Returns true when an archive is present in the cache afterwards. Missing
  ## binaries, unreachable mirrors and checksum failures all return false so
  ## the caller silently falls back to building from source.
  let binrepos = getConfigValue("Repositories", "binRepos").split(" ")
  if binrepos.len == 0 or (binrepos.len == 1 and isEmptyOrWhitespace(binrepos[0])):
    return false

  let tarball = pkg.pkg & "-" & pkg.versionString & ".kpkg"
  let dest = kpkgArchivesDir & "/system/" & kTarget & "/" & tarball

  if fileExists(dest):
    return true

  discard existsOrCreateDir(kpkgArchivesDir & "/system/" & kTarget)

  for binrepo in binrepos:
    if isEmptyOrWhitespace(binrepo):
      continue
    let url = "https://" & binrepo & "/archives/system/" & kTarget & "/" & tarball
    try:
      download(url, dest, raiseWhenFail = false)
    except CatchableError:
      debug "binCache: download failed for " & tarball & ": " &
          getCurrentExceptionMsg()
      continue

    if fileExists(dest):
      # Binaries are checksummed against the first source entry when the
      # recipe provides one; otherwise the mirror is trusted as install does.
      let expected = if pkg.sources.len > 0: pkg.sources[0].b2sum else: ""
      if expected != "":
        let actual = getSum(dest, "b2")
        if expected != actual:
          warn "binCache: checksum mismatch for " & tarball &
              ", falling back to a source build"
          removeFile(dest)
          return false
      info "using cached binary for " & pkg.pkg
      return true

  return false
