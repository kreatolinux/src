import os
import tables
import strutils
import sequtils
import installcmd
import ../modules/sqlite
import ../modules/logger
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
  let init = getInit(root)
  var deps: seq[string]
  var depGraph: dependencyGraph
  var gD: seq[string]

  if packages.len == 0:
    error("please enter a package name")
    quit(1)

  var fullRootPath = expandFilename(root)
  var ignoreInit = false

  var allDependents: seq[string]

  # Check for commit-based builds - all packages with commits must use the same commit
  var commit = ""
  var commitRepo = ""
  var headRunfileCache = initTable[string, runFile]()
  var originalRef = ""
  var packagesWithCommit: seq[string] = @[]

  for pkg in packages:
    let pkgInfo = parsePkgInfo(pkg)
    if pkgInfo.commit != "":
      if commit == "":
        commit = pkgInfo.commit
      elif commit != pkgInfo.commit:
        error("All packages must use the same commit hash. Found '" & commit &
            "' and '" & pkgInfo.commit & "'")
        quit(1)
      packagesWithCommit.add(pkgInfo.name)

  # Handle commit-based build setup
  if commit != "":
    info "Building " & packagesWithCommit.join(", ") & " from commit " & commit

    # Find which repo contains this commit
    commitRepo = findRepoWithCommit(commit)
    if commitRepo == "":
      error("Commit '" & commit & "' not found in any configured repository")
      quit(1)

    info "Found commit in repo: " & commitRepo

    # Cache all runfiles from HEAD before checkout
    headRunfileCache = cacheRepoRunfiles(commitRepo)
    debug "Cached " & $headRunfileCache.len & " runfiles from HEAD"

    # Save original ref for restoration
    originalRef = getCurrentRef(commitRepo)

    # Save commit build state for crash recovery
    let buildState = CommitBuildState(
      repoPath: commitRepo,
      originalRef: originalRef,
      commit: commit
    )
    saveCommitBuildState(buildState)

    # Checkout the commit
    if not checkoutCommit(commitRepo, commit):
      error("Failed to checkout commit '" & commit & "'")
      quit(1)
    info "Checked out commit " & commit

  # Use try/finally to ensure repo is restored on success or failure
  try:
    try:
      # Build the dependency graph once
      (deps, depGraph) = dephandlerWithGraph(packages, isBuild = true,
              root = fullRootPath, forceInstallAll = forceInstallAll,
              isInstallDir = isInstallDir, ignoreInit = ignoreInit,
              useBootstrap = bootstrap,
              useCacheIfAvailable = useCacheIfAvailable,
              commit = commit, commitRepo = commitRepo,
              headRunfileCache = headRunfileCache)

      printReplacesPrompt(deps, fullRootPath, true)

      # Check for packages that depend on what we're building
      gD = getDependents(deps)

      # Get packages that have runtime dependencies on the packages being built
      var runtimeDependents: seq[string]
      for pkg in packages:
        let pkgSplit = parsePkgInfo(pkg)
        runtimeDependents = runtimeDependents & getRuntimeDependents(@[
                pkgSplit.name], fullRootPath)

      # Remove duplicates and packages already in dependents
      runtimeDependents = deduplicate(runtimeDependents).filterIt(it notin gD)

      # Combine all dependents
      allDependents = deduplicate(gD & runtimeDependents)

      # If we have dependents, rebuild the graph with them included
      if not isEmptyOrWhitespace(allDependents.join("")):
        let allPackages = deduplicate(packages&allDependents)
        (deps, depGraph) = dephandlerWithGraph(allPackages, isBuild = true,
                root = fullRootPath, forceInstallAll = forceInstallAll,
                isInstallDir = isInstallDir, ignoreInit = ignoreInit,
                useBootstrap = bootstrap,
                useCacheIfAvailable = useCacheIfAvailable,
                commit = commit, commitRepo = commitRepo,
                headRunfileCache = headRunfileCache)
    except CatchableError:
      raise getCurrentException()

    var p: seq[string]

    for currentPackage in packages:
      p = p&currentPackage
      if findPkgRepo(currentPackage&"-"&init) != "":
        p = p&(currentPackage&"-"&init)

    # Use the graph to get the correct build order for ALL packages (dependencies + targets)
    deps = flattenDependencyOrder(depGraph).filterIt(it.len != 0)

    # If building a package that has bootstrap deps but we're not in bootstrap mode,
    # ensure it's rebuilt AFTER its full BUILD_DEPENDS by moving it to the end
    if not bootstrap:
      for pkg in p:
        let pkgInfo = parsePkgInfo(pkg)
        # Check if package has bootstrap deps by looking at the graph
        if depGraph.nodes.hasKey(pkgInfo.name) and depGraph.nodes[
                pkgInfo.name].metadata.bsdeps.len > 0:
          # This package has bootstrap deps - move it to the end to ensure
          # it's rebuilt after all its full BUILD_DEPENDS are available
          deps = deps.filterIt(it != pkg)&pkg

    printReplacesPrompt(p, fullRootPath, isInstallDir = isInstallDir)

    if isInstallDir:
      printPackagesPrompt(deps.join(" "), yes, no, packages,
              dependents = allDependents)
    else:
      printPackagesPrompt(deps.join(" "), yes, no, @[""],
              dependents = allDependents)

    let pBackup = p

    p = @[]

    if not isInstallDir:
      for i in pBackup:
        let packageSplit = parsePkgInfo(i)
        if "/" in packageSplit.nameWithRepo:
          p = p&packageSplit.name
        else:
          p = p&packageSplit.name

    var pkgPaths = initTable[string, string]()
    if isInstallDir:
      for pkg in packages:
        pkgPaths[lastPathPart(pkg)] = absolutePath(pkg)

    # Create sandbox configuration with commit context
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
      commit = commit,
      commitRepo = commitRepo,
      headRunfileCache = headRunfileCache
    )

    # Build all packages in sandbox
    result = buildAllPackagesInSandbox(deps, depGraph, sandboxCfg,
            builderWrapper, installPkgWrapper)
  finally:
    # Restore repo to original state if we checked out a commit
    if commit != "" and commitRepo != "" and originalRef != "":
      info "Restoring repo to " & originalRef
      discard restoreRepo(commitRepo, originalRef)
      clearCommitBuildState()
