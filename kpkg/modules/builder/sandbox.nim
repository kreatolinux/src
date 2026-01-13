#[
  This module handles sandbox/overlay setup and package building loop.
  
  Extracted from buildcmd.nim to provide a clean interface for
  building packages in an isolated sandbox environment.
]#

import os
import sets
import tables
import strutils
import sequtils
import ./types
import ../logger
import ../config
import ../isolation
import ../dephandler
import ../processes
import ../commonPaths
import ../commonTasks

proc buildPackageInSandbox*(pkgName: string, depGraph: dependencyGraph,
                            sandboxCfg: SandboxConfig,
                            builderProc: BuilderProc,
                            installPkgProc: InstallPkgProc) =
  ## Sets up sandbox for a single package and builds it.
  ##
  ## Handles overlay mount, dependency installation, postinstall, ldconfig.
  ##
  ## Parameters:
  ##   pkgName: Package name to build
  ##   depGraph: Pre-computed dependency graph
  ##   sandboxCfg: Sandbox configuration
  ##   builderProc: Callback to builder() function
  ##   installPkgProc: Callback for installing packages to overlay

  createOrUpgradeEnv(sandboxCfg.root)

  let pkgTmp = parsePkgInfo(pkgName)

  # Extract sandbox dependencies from the graph
  let sandboxDeps = getSandboxDepsFromGraph(pkgTmp.name, depGraph,
          sandboxCfg.bootstrap, sandboxCfg.fullRootPath,
          sandboxCfg.forceInstallAll, sandboxCfg.isInstallDir,
          sandboxCfg.ignoreInit)

  debug "sandboxDeps for " & pkgTmp.name & " = \"" & sandboxDeps.join(" ") & "\""
  var allInstalledDeps: seq[string]

  # Prepare overlay directories first
  discard prepareOverlayDirs(error = "preparing overlay directories")

  if sandboxCfg.target != "default" and sandboxCfg.target != kpkgTarget("/"):
    for d in sandboxDeps:
      if isEmptyOrWhitespace(d):
        continue

      debug "buildPackageInSandbox: installPkg ran for '" & d & "'"
      let installCfg = InstallConfig(
        repo: findPkgRepo(d),
        package: d,
        root: kpkgOverlayPath & "/upperDir",
        isUpgrade: false,
        kTarget: sandboxCfg.target,
        manualInstallList: @[],
        umount: false,
        disablePkgInfo: true
      )
      installPkgProc(installCfg)
  else:
    # Collect all transitive runtime dependencies
    var visited = initHashSet[string]()
    allInstalledDeps = deduplicate(collectRuntimeDepsFromGraph(
            sandboxDeps, depGraph, visited))

    # Install build dependencies to upperDir
    for d in sandboxDeps:
      discard installFromRoot(d, sandboxCfg.root,
              kpkgOverlayPath & "/upperDir",
              ignorePostInstall = true)

  # Mount the overlayfs after dependencies installed
  discard mountOverlayFilesystem(error = "mounting overlay filesystem")

  # Run postinstall scripts in merged overlay
  if sandboxCfg.target == "default" or sandboxCfg.target == kpkgTarget("/"):
    debug "builder-ng: postinstall is running"
    for d in deduplicate(allInstalledDeps):
      if not isEmptyOrWhitespace(d):
        runPostInstall(d)

    discard runLdconfig(kpkgMergedPath, silentMode = true)
  else:
    discard runLdconfig(kpkgMergedPath, silentMode = true)

  let packageSplit = parsePkgInfo(pkgName)

  # Determine if this is a bootstrap build
  let isBootstrapBuild = sandboxCfg.bootstrap and depGraph.nodes.hasKey(pkgTmp.name) and
          depGraph.nodes[pkgTmp.name].metadata.bsdeps.len > 0

  var customRepo = ""
  var isInstallDirFinal = false
  var actualPkgName: string

  # Try to get repo from graph first
  if depGraph.nodes.hasKey(pkgTmp.name):
    let r = depGraph.nodes[pkgTmp.name].repo
    if r != "local" and r.startsWith("/etc/kpkg/repos/"):
      customRepo = lastPathPart(r)

  if sandboxCfg.isInstallDir and sandboxCfg.pkgPaths.hasKey(pkgTmp.name):
    actualPkgName = sandboxCfg.pkgPaths[pkgTmp.name]
    isInstallDirFinal = true
  else:
    if "/" in packageSplit.nameWithRepo:
      customRepo = lastPathPart(packageSplit.repo)
      actualPkgName = packageSplit.name
    else:
      actualPkgName = packageSplit.name

  if isBootstrapBuild:
    info("Performing bootstrap build for " & pkgName)

  # Create BuildConfig for this package
  let buildCfg = BuildConfig(
    package: actualPkgName,
    destdir: sandboxCfg.fullRootPath,
    offline: false,
    dontInstall: sandboxCfg.dontInstall,
    useCacheIfAvailable: sandboxCfg.useCacheIfAvailable,
    tests: sandboxCfg.tests,
    manualInstallList: sandboxCfg.manualInstallList,
    customRepo: customRepo,
    isInstallDir: isInstallDirFinal,
    isUpgrade: sandboxCfg.isUpgrade,
    target: sandboxCfg.target,
    actualRoot: sandboxCfg.root,
    ignorePostInstall: sandboxCfg.ignorePostInstall,
    noSandbox: false,
    ignoreTarget: false,
    ignoreUseCacheIfAvailable: sandboxCfg.ignoreUseCacheIfAvailable,
    isBootstrap: isBootstrapBuild
  )

  discard builderProc(buildCfg)

  info("built " & pkgName & " successfully")


proc buildAllPackagesInSandbox*(deps: seq[string], depGraph: dependencyGraph,
                                sandboxCfg: SandboxConfig,
                                builderProc: BuilderProc,
                                installPkgProc: InstallPkgProc): int =
  ## Iterates over all packages and builds each in sandbox.
  ##
  ## Returns 0 on success.

  for pkg in deps:
    try:
      buildPackageInSandbox(pkg, depGraph, sandboxCfg,
              builderProc, installPkgProc)
    except CatchableError:
      when defined(release):
        fatal("Undefined error occured")
      else:
        raise getCurrentException()

  info("built all packages successfully")
  return 0
