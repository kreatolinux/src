#[
  This module defines types used across the builder modules.
  
  Centralizes type definitions to reduce proc argument count
  and improve code clarity.
]#

import tables
import parsecfg
import ../runparser

type
  BuildConfig* = object
    ## Configuration for a package build operation.
    ## Groups all build-time settings into a single object.

    # Package identification
    package*: string ## Package name (may include path if isInstallDir)
    actualPackage*: string ## Resolved package name (without path)
    repo*: string ## Repository path
    path*: string ## Full path to package directory
    customRepo*: string ## Custom repository name (optional)

    # Target configuration
    target*: string ## Target triplet or "default"
    kTarget*: string ## Resolved kpkg target string
    arch*: string ## Architecture (x86_64, aarch64, etc.)
    actualRoot*: string ## Actual root for cross-compilation

    # Destination paths
    destdir*: string ## Installation destination
    srcDir*: string ## Source directory (resolved after autocd)

    # Build options
    offline*: bool ## Don't download sources
    dontInstall*: bool ## Build but don't install
    useCacheIfAvailable*: bool ## Use cached tarballs if available
    tests*: bool ## Run test suite
    noSandbox*: bool ## Disable sandbox/overlay
    isBootstrap*: bool ## Bootstrap build mode
    ignoreTarget*: bool ## Ignore target mismatch

    # Installation options
    isInstallDir*: bool ## Package arg is a directory path
    isUpgrade*: bool ## This is an upgrade operation
    ignorePostInstall*: bool ## Skip postinstall scripts
    manualInstallList*: seq[string] ## Manually installed packages
    ignoreUseCacheIfAvailable*: seq[string] ## Packages to rebuild even if cached

    # Override configuration
    override*: Config ## Per-package override config

    # Commit-based build options
    commit*: string ## Commit hash for commit-based builds (e.g., "e24958")
    commitRepo*: string ## The repo that was checked out to the commit
    headRunfileCache*: Table[string, runFile] ## Cached runfiles at HEAD (before checkout)

  BuildState* = object
    ## Runtime state during a build operation.
    ## Tracks parsed data and computed values.

    pkg*: runFile ## Parsed runfile
    envVars*: Table[string, string] ## Environment variables for build
    exists*: BuildFunctions ## Which build functions exist
    amountOfFolders*: int ## Number of source folders
    folder*: string ## Single folder path (for autocd)

  BuildFunctions* = object
    ## Tracks which build functions exist in a runfile.
    prepare*: bool
    package*: bool
    check*: bool
    build*: bool
    packageInstall*: bool ## package_{name} exists
    packageBuild*: bool   ## build_{name} exists

  CacheConfig* = object
    ## Configuration for cache operations.
    actualPackage*: string
    kTarget*: string
    useCacheIfAvailable*: bool
    dontInstall*: bool
    ignoreUseCacheIfAvailable*: seq[string]

  SandboxConfig* = object
    ## Configuration for sandbox build operations.
    ## Used by build() to set up isolated build environments.
    fullRootPath*: string ## Full path to root directory
    target*: string ## Build target triplet or "default"
    bootstrap*: bool ## Whether this is a bootstrap build
    forceInstallAll*: bool ## Force install all dependencies
    isInstallDir*: bool ## Whether building from local directory
    ignoreInit*: bool ## Whether to ignore init system packages
    dontInstall*: bool ## Skip installation after build
    useCacheIfAvailable*: bool ## Use cached tarballs if available
    tests*: bool ## Run test suite
    isUpgrade*: bool ## Whether this is an upgrade
    ignorePostInstall*: bool ## Skip postinstall scripts
    manualInstallList*: seq[string] ## List of manually installed packages
    ignoreUseCacheIfAvailable*: seq[string] ## Packages to skip cache for
    root*: string ## Root path
    pkgPaths*: Table[string, string] ## Map of package names to local paths
    # Commit-based build options
    commit*: string ## Commit hash for commit-based builds
    commitRepo*: string ## The repo that was checked out to the commit
    headRunfileCache*: Table[string, runFile] ## Cached runfiles at HEAD

  InstallConfig* = object
    ## Configuration for package installation to overlay.
    repo*: string                   ## Repository path
    package*: string                ## Package name
    root*: string                   ## Installation root
    isUpgrade*: bool                ## Whether this is an upgrade
    kTarget*: string                ## Target triplet
    manualInstallList*: seq[string] ## Manually installed packages
    umount*: bool                   ## Whether to unmount after install
    disablePkgInfo*: bool           ## Whether to disable pkginfo writing

  # Proc type aliases for callbacks (avoids circular imports)
  BuilderProc* = proc(cfg: BuildConfig): bool
  InstallPkgProc* = proc(cfg: InstallConfig)

proc initBuildConfig*(package: string, destdir: string, offline = false,
                      dontInstall = false, useCacheIfAvailable = false,
                      tests = false, manualInstallList: seq[string] = @[],
                      customRepo = "", isInstallDir = false,
                      isUpgrade = false, target = "default",
                      actualRoot = "default", ignorePostInstall = false,
                      noSandbox = false, ignoreTarget = false,
                      ignoreUseCacheIfAvailable: seq[string] = @[""],
                      isBootstrap = false,
                      commit = "", commitRepo = "",
                      headRunfileCache = initTable[string, runFile]()): BuildConfig =
  ## Creates a BuildConfig from individual parameters.
  ## Useful for backwards compatibility with existing call sites.

  result = BuildConfig(
    package: package,
    destdir: destdir,
    offline: offline,
    dontInstall: dontInstall,
    useCacheIfAvailable: useCacheIfAvailable,
    tests: tests,
    manualInstallList: manualInstallList,
    customRepo: customRepo,
    isInstallDir: isInstallDir,
    isUpgrade: isUpgrade,
    target: target,
    actualRoot: actualRoot,
    ignorePostInstall: ignorePostInstall,
    noSandbox: noSandbox,
    ignoreTarget: ignoreTarget,
    ignoreUseCacheIfAvailable: ignoreUseCacheIfAvailable,
    isBootstrap: isBootstrap,
    commit: commit,
    commitRepo: commitRepo,
    headRunfileCache: headRunfileCache
  )

  # These get resolved later
  result.actualPackage = ""
  result.repo = ""
  result.path = ""
  result.kTarget = ""
  result.arch = ""
  result.srcDir = ""
  result.override = newConfig()

proc initSandboxConfig*(fullRootPath: string, target: string,
                        bootstrap: bool, forceInstallAll: bool,
                        isInstallDir: bool, ignoreInit: bool,
                        dontInstall: bool, useCacheIfAvailable: bool,
                        tests: bool, isUpgrade: bool,
                        ignorePostInstall: bool,
                        manualInstallList: seq[string],
                        ignoreUseCacheIfAvailable: seq[string],
                        root: string,
                        pkgPaths: Table[string, string],
                        commit = "", commitRepo = "",
                        headRunfileCache = initTable[string, runFile]()): SandboxConfig =
  ## Creates a SandboxConfig from individual parameters.
  SandboxConfig(
    fullRootPath: fullRootPath,
    target: target,
    bootstrap: bootstrap,
    forceInstallAll: forceInstallAll,
    isInstallDir: isInstallDir,
    ignoreInit: ignoreInit,
    dontInstall: dontInstall,
    useCacheIfAvailable: useCacheIfAvailable,
    tests: tests,
    isUpgrade: isUpgrade,
    ignorePostInstall: ignorePostInstall,
    manualInstallList: manualInstallList,
    ignoreUseCacheIfAvailable: ignoreUseCacheIfAvailable,
    root: root,
    pkgPaths: pkgPaths,
    commit: commit,
    commitRepo: commitRepo,
    headRunfileCache: headRunfileCache
  )

proc toCacheConfig*(cfg: BuildConfig): CacheConfig =
  ## Extracts cache-related config from BuildConfig.
  CacheConfig(
    actualPackage: cfg.actualPackage,
    kTarget: cfg.kTarget,
    useCacheIfAvailable: cfg.useCacheIfAvailable,
    dontInstall: cfg.dontInstall,
    ignoreUseCacheIfAvailable: cfg.ignoreUseCacheIfAvailable
  )
