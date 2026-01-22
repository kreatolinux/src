import os
import tables
import strutils
import sequtils
import installcmd
import ../modules/sqlite
import ../../common/logging
import ../modules/config
import ../modules/lockfile
import ../modules/runparser
import ../modules/dephandler
import ../modules/commonTasks
import ../modules/commonPaths
import ../modules/gitutils
import ../modules/builder/main
import ../modules/builder/types
import ../modules/builder/cache
import ../modules/builder/sources
import ../modules/builder/context
import ../modules/builder/packager
import ../modules/builder/executor
import ../modules/builder/environment
import ../modules/builder/sandbox
import ../modules/builder/commitctx

proc builder*(cfg: BuildConfig): bool =
  ## Builds a package using the provided configuration.
  ##
  ## This is the main entry point for building a single package.
  ## It handles: path resolution, runfile parsing, cache checking,
  ## source downloading, environment setup, build execution, and packaging.

  var cfg = cfg # Make mutable copy

  debug "builder ran, package: '" & cfg.package & "', destdir: '" & cfg.destdir & "' root: '" & kpkgSrcDir & "', useCacheIfAvailable: '" & (
          $cfg.useCacheIfAvailable) & "'"

  preliminaryChecks(cfg.target, cfg.actualRoot)

  # Resolve paths (repo, path, actualPackage)
  resolvePaths(cfg, cfg.customRepo)

  # Remove directories if they exist
  removeDir(kpkgBuildRoot)
  removeDir(kpkgSrcDir)

  cfg.arch = getArch(cfg.target)
  cfg.kTarget = getKtarget(cfg.target, cfg.destdir)

  initEnv(cfg.actualPackage, cfg.kTarget)

  # Enter into the source directory
  setCurrentDir(kpkgSrcDir)

  # Initialize build state (parse runfile)
  var state = initBuildState(cfg)

  # Load override config
  cfg.override = loadOverrideConfig(cfg.package)

  # Check cache and install from it if available
  if shouldInstallFromCache(cfg.toCacheConfig(), state.pkg):
    debug "Tarball (and the sum) already exists, going to install"
    if cfg.destdir != "/" and cfg.target == "default":
      installPkg(cfg.repo, cfg.actualPackage, "/", state.pkg, cfg.manualInstallList,
              ignorePostInstall = cfg.ignorePostInstall)

    if cfg.kTarget == kpkgTarget(cfg.destdir):
      installPkg(cfg.repo, cfg.actualPackage, cfg.destdir, state.pkg, cfg.manualInstallList,
              ignorePostInstall = cfg.ignorePostInstall)
    else:
      info "the package target doesn't match the one on '" & cfg.destdir & "', skipping installation"

    cleanupAfterCacheInstall()
    return true

  debug "Tarball (and the sum) doesn't exist, going to continue"

  # Handle group packages
  if state.pkg.isGroup:
    debug "Package is a group package"
    installPkg(cfg.repo, cfg.actualPackage, cfg.destdir, state.pkg, cfg.manualInstallList,
            ignorePostInstall = cfg.ignorePostInstall)
    removeDir(kpkgBuildRoot)
    removeDir(kpkgSrcDir)
    removeLockfile()
    return true

  createDir(kpkgTempDir2)

  # Detect which build functions exist
  state.exists = detectBuildFunctions(state.pkg, cfg.actualPackage)

  # Download and extract sources
  sourceDownloader(state.pkg, cfg.actualPackage, kpkgSrcDir, cfg.path)

  # Set ownership and count folders
  (state.amountOfFolders, state.folder) = countAndFindSourceFolders(kpkgSrcDir)
  setSourceOwnership(kpkgSrcDir)

  # Resolve source directory (handle autocd)
  cfg.srcDir = resolveSourceDir(state.pkg, kpkgSrcDir, state.folder,
      state.amountOfFolders)

  # Initialize environment variables
  state.envVars = initBuildEnvVars(cfg)

  # Initialize Run3 context
  let ctx = initBuildContext(cfg, state)

  # Execute build steps
  executeBuildSteps(ctx, state, cfg.actualPackage, cfg.tests)

  discard createPackage(cfg.actualPackage, state.pkg, cfg.kTarget)

  # Install package to root as well so dependency errors don't happen
  # because the dep is installed to destdir but not root.
  if cfg.destdir != "/" and not packageExists(cfg.actualPackage) and (
          not cfg.dontInstall) and cfg.target == "default":
    installPkg(cfg.repo, cfg.actualPackage, "/", state.pkg, cfg.manualInstallList,
            isUpgrade = cfg.isUpgrade, ignorePostInstall = cfg.ignorePostInstall)

  if (not cfg.dontInstall) and (cfg.kTarget == kpkgTarget(cfg.destdir)):
    installPkg(cfg.repo, cfg.actualPackage, cfg.destdir, state.pkg, cfg.manualInstallList,
            isUpgrade = cfg.isUpgrade, ignorePostInstall = cfg.ignorePostInstall)
  else:
    info "the package target doesn't match the one on '" & cfg.destdir & "', skipping installation"

  removeLockfile()

  when defined(release):
    removeDir(kpkgSrcDir)
    removeDir(kpkgTempDir2)

  return false


# Wrapper procs for sandbox callbacks
proc builderWrapper(cfg: BuildConfig): bool =
  ## Wrapper for builder() to match BuilderProc signature.
  builder(cfg)

proc installPkgWrapper(cfg: InstallConfig) =
  ## Wrapper for installPkg() to match InstallPkgProc signature.
  installPkg(cfg.repo, cfg.package, cfg.root,
             isUpgrade = cfg.isUpgrade, kTarget = cfg.kTarget,
             manualInstallList = cfg.manualInstallList,
             umount = cfg.umount, disablePkgInfo = cfg.disablePkgInfo)


proc build*(no = false, yes = false, root = "/",
    packages: seq[string],
            useCacheIfAvailable = true, forceInstallAll = false,
                    dontInstall = false, tests = true,
                            ignorePostInstall = false, isInstallDir = false,
                            isUpgrade = false, target = "default",
                            bootstrap = false): int =
  ## Build and install packages.
  ##
  ## Supports commit-based builds with syntax: package#commit
  ## When a commit hash is specified, the repo containing that commit
  ## is checked out to that commit for the build, then restored.

  if packages.len == 0:
    error("please enter a package name")
    quit(1)

  let init = getInit(root)
  let fullRootPath = expandFilename(root)
  let ignoreInit = false

  withCommitContext(packages):
    # Build dependency context for resolveBuildOrder
    let depCtx = dependencyContext(
      root: fullRootPath,
      isBuild: true,
      useBootstrap: bootstrap,
      ignoreInit: ignoreInit,
      ignoreCircularDeps: false,
      forceInstallAll: forceInstallAll,
      useCacheIfAvailable: useCacheIfAvailable,
      init: init,
      commit: commitCtx.commit,
      commitRepo: commitCtx.commitRepo,
      headRunfileCache: commitCtx.headRunfileCache
    )

    # Resolve complete build order (handles dependents, graph rebuild, bootstrap reordering)
    let (deps, depGraph, allDependents) = resolveBuildOrder(
      packages, depCtx, bootstrap, isInstallDir
    )

    # Build package list with init variants
    var p: seq[string]
    for currentPackage in packages:
      p = p & currentPackage
      if findPkgRepo(currentPackage & "-" & init) != "":
        p = p & (currentPackage & "-" & init)

    # UI prompts
    printReplacesPrompt(deps, fullRootPath, true)
    printReplacesPrompt(p, fullRootPath, isInstallDir = isInstallDir)

    if isInstallDir:
      printPackagesPrompt(deps.join(" "), yes, no, packages,
              dependents = allDependents)
    else:
      printPackagesPrompt(deps.join(" "), yes, no, @[""],
              dependents = allDependents)

    # Normalize package names (strip repo prefix if not isInstallDir)
    let pBackup = p
    p = @[]
    if not isInstallDir:
      for i in pBackup:
        let packageSplit = parsePkgInfo(i)
        p = p & packageSplit.name

    # Build package paths table for isInstallDir mode
    var pkgPaths = initTable[string, string]()
    if isInstallDir:
      for pkg in packages:
        pkgPaths[lastPathPart(pkg)] = absolutePath(pkg)

    # Get build dependents for cache invalidation
    let gD = getDependents(deps)

    # Create sandbox configuration
    let sandboxCfg = initSandboxConfig(
      fullRootPath = fullRootPath,
      target = target,
      bootstrap = bootstrap,
      forceInstallAll = forceInstallAll,
      isInstallDir = isInstallDir,
      ignoreInit = ignoreInit,
      dontInstall = dontInstall,
      useCacheIfAvailable = useCacheIfAvailable,
      tests = tests,
      isUpgrade = isUpgrade,
      ignorePostInstall = ignorePostInstall,
      manualInstallList = p,
      ignoreUseCacheIfAvailable = gD,
      root = root,
      pkgPaths = pkgPaths,
      commit = commitCtx.commit,
      commitRepo = commitCtx.commitRepo,
      headRunfileCache = commitCtx.headRunfileCache
    )

    # Build all packages in sandbox
    result = buildAllPackagesInSandbox(deps, depGraph, sandboxCfg,
            builderWrapper, installPkgWrapper)
