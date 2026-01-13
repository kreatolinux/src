#[
  This module handles build environment variable setup for the builder.
  
  Extracted from buildcmd.nim to provide a clean interface for
  initializing all environment variables needed during package builds.
]#

import os
import posix
import tables
import strutils
import parsecfg
import posix_utils
import ./types
import ../config
import ../sqlite
import ../commonPaths
import ../commonTasks

proc initBuildEnvVars*(cfg: BuildConfig): Table[string, string] =
  ## Initializes all environment variables for the build process.
  ##
  ## Includes: CC, CXX, CFLAGS, CXXFLAGS, ccache config,
  ## KPKG_ARCH, KPKG_TARGET, KPKG_HOST_TARGET, SRCDIR, PACKAGENAME, etc.

  var envVars = initTable[string, string]()

  let cc = getConfigValue("Options", "cc", "cc")
  let cxx = getConfigValue("Options", "cxx", "c++")

  # Determine actual target
  var actTarget: string
  let tSplit = cfg.target.split("-")
  if tSplit.len >= 4:
    actTarget = tSplit[0] & "-" & tSplit[1] & "-" & tSplit[2]
  else:
    actTarget = cfg.target

  # Bootstrap flag
  if cfg.isBootstrap:
    envVars["KPKG_BOOTSTRAP"] = "1"

  # Architecture info
  var arch: string
  if cfg.target != "default":
    arch = cfg.target.split("-")[0]
  else:
    arch = uname().machine

  if arch == "amd64":
    arch = "x86_64"

  envVars["KPKG_ARCH"] = arch
  envVars["KPKG_TARGET"] = actTarget
  envVars["KPKG_HOST_TARGET"] = systemTarget(cfg.actualRoot)

  # Unset host target if building for default/native
  if not (actTarget != "default" and actTarget != systemTarget("/")):
    envVars.del("KPKG_HOST_TARGET")

  # ccache configuration
  if parseBool(cfg.override.getSectionValue("Other", "ccache", getConfigValue(
          "Options", "ccache", "false"))) and packageExists("ccache"):
    if not dirExists(kpkgCacheDir & "/ccache"):
      createDir(kpkgCacheDir & "/ccache")
    setFilePermissions(kpkgCacheDir & "/ccache", {fpUserExec, fpUserWrite,
            fpUserRead, fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})
    discard posix.chown(cstring(kpkgCacheDir & "/ccache"), 999, 999)

    envVars["CCACHE_DIR"] = kpkgCacheDir & "/ccache"
    envVars["PATH"] = "/usr/lib/ccache:" & getEnv("PATH")

  # Compiler settings for native builds
  if actTarget == "default" or actTarget == systemTarget("/"):
    envVars["CC"] = cc
    envVars["CXX"] = cxx

  # Extra arguments from override
  if not isEmptyOrWhitespace(cfg.override.getSectionValue("Flags",
      "extraArguments")):
    envVars["KPKG_EXTRA_ARGUMENTS"] = cfg.override.getSectionValue("Flags", "extraArguments")

  # Source directory and package name
  envVars["SRCDIR"] = cfg.srcDir
  envVars["PACKAGENAME"] = cfg.actualPackage

  # CXXFLAGS
  let cxxflags = cfg.override.getSectionValue("Flags", "cxxflags", getConfigValue(
          "Options", "cxxflags"))
  if not isEmptyOrWhitespace(cxxflags):
    envVars["CXXFLAGS"] = cxxflags

  # CFLAGS
  let cflags = cfg.override.getSectionValue("Flags", "cflags", getConfigValue(
          "Options", "cflags"))
  if not isEmptyOrWhitespace(cflags):
    envVars["CFLAGS"] = cflags

  return envVars
