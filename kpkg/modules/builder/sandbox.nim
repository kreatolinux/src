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
import ../../../common/logging
import ../config
import ../isolation
import ../dephandler
import ../processes
import ../commonPaths
import ../commonTasks
import ../runparser
import ../sqlite
import ../../commands/installcmd

proc buildPackageInSandbox*(pkgName: string, depGraph: dependencyGraph,
                            sandboxCfg: SandboxConfig,
                            builderProc: BuilderProc,
                            installPkgProc: InstallPkgProc): seq[string] =
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

  # Resolve kTarget for tarball lookup — matches how the builder stores tarballs
  let sandboxKTarget = if sandboxCfg.target == "default" or sandboxCfg.target ==
      kpkgTarget("/"):
    kpkgTarget(sandboxCfg.fullRootPath)
  else:
    sandboxCfg.target
  debug "sandboxKTarget: '" & sandboxKTarget & "' (target: '" &
      sandboxCfg.target & "', fullRootPath: '" & sandboxCfg.fullRootPath & "')"

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
        kTarget: sandboxKTarget,
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

    # If the package isn't in the dep graph (e.g. dynamically added consumer),
    # fall back to parsing the runfile directly for build deps
    if sandboxDeps.len == 0:
      let pkgDir = findPkgRepo(pkgTmp.name) & "/" & pkgTmp.name
      try:
        let rf = parseRunfile(pkgDir)
        for bdep in rf.bdeps:
          if packageExists(bdep, sandboxCfg.root):
            debug "buildPackageInSandbox: installing build dep '" & bdep &
                "' for '" & pkgTmp.name & "'"
            discard installFromRoot(bdep, sandboxCfg.root,
                    kpkgOverlayPath & "/upperDir",
                    ignorePostInstall = true)
      except:
        debug "buildPackageInSandbox: could not parse runfile for '" &
            pkgTmp.name & "'"

    # Install the package with changed SONAME into the sandbox so consumers
    # build against the new library version
    if sandboxCfg.sonameChangedPackage != "":
      debug "buildPackageInSandbox: installing changed soname package '" &
          sandboxCfg.sonameChangedPackage & "'"
      if sandboxCfg.target != "default" and sandboxCfg.target != kpkgTarget("/"):
        let installCfg = InstallConfig(
          repo: findPkgRepo(sandboxCfg.sonameChangedPackage),
          package: sandboxCfg.sonameChangedPackage,
          root: kpkgOverlayPath & "/upperDir",
          isUpgrade: false,
          kTarget: sandboxKTarget,
          manualInstallList: @[],
          umount: false,
          disablePkgInfo: true
        )
        installPkgProc(installCfg)
      else:
        debug "buildPackageInSandbox: installing soname package '" &
            sandboxCfg.sonameChangedPackage & "' to overlay via installPkg"
        installPkg(findPkgRepo(sandboxCfg.sonameChangedPackage),
                sandboxCfg.sonameChangedPackage, kpkgOverlayPath & "/upperDir",
                kTarget = sandboxKTarget, manualInstallList = @[],
                ignorePostInstall = true, umount = false)
    # Install rebuilt consumers to upperDir so subsequent builds get updated libs/binaries
    for r in sandboxCfg.rebuiltConsumers:
      if r != pkgName:
        debug "buildPackageInSandbox: installing rebuilt consumer '" & r & "' to overlay"
        installPkgProc(InstallConfig(
          repo: findPkgRepo(r),
          package: r,
          root: kpkgOverlayPath & "/upperDir",
          isUpgrade: false,
          kTarget: sandboxKTarget,
          manualInstallList: @[],
          umount: false,
          disablePkgInfo: true,
          ignorePostInstall: true
        ))

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
  var buildCfg = BuildConfig(
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
    isBootstrap: isBootstrapBuild,
    skipHostInstall: true
  )

  discard builderProc(buildCfg)

  # Install to host if not a SONAME-changed package, so rebuilt
  # consumers replace the old system binaries.
  if not buildCfg.sonameChanged and not sandboxCfg.dontInstall and
      sandboxCfg.target == "default":
    debug "buildPackageInSandbox: installing " & actualPkgName & " to host"
    installPkg(findPkgRepo(actualPkgName), actualPkgName,
            sandboxCfg.fullRootPath,
            manualInstallList = @[], kTarget = sandboxKTarget,
            ignorePostInstall = true, umount = false)

  if buildCfg.sonameChanged:
    return buildCfg.consumersToRebuild

  info("built " & pkgName & " successfully")


proc buildAllPackagesInSandbox*(deps: var seq[string], depGraph: dependencyGraph,
                                sandboxCfg: var SandboxConfig,
                                builderProc: BuilderProc,
                                installPkgProc: InstallPkgProc): int =
  ## Iterates over all packages and builds each in sandbox.
  ##
  ## Returns 0 on success.

  var sonameSourceMap = initTable[string, string]()
  var sonameSources: seq[string]
  let sandboxKTarget = if sandboxCfg.target == "default" or sandboxCfg.target ==
      kpkgTarget("/"):
    kpkgTarget(sandboxCfg.fullRootPath)
  else:
    sandboxCfg.target
  var i = 0
  while i < deps.len:
    let pkg = deps[i]
    try:
      sandboxCfg.sonameChangedPackage = sonameSourceMap.getOrDefault(pkg, "")
      if sandboxCfg.sonameChangedPackage != "":
        debug "buildAll: " & pkg & " is SONAME consumer of " &
            sandboxCfg.sonameChangedPackage
      let consumers = buildPackageInSandbox(pkg, depGraph, sandboxCfg,
              builderProc, installPkgProc)
      if consumers.len > 0:
        sonameSources.add(pkg)
        sandboxCfg.rebuiltConsumers.add(pkg)
      elif sonameSourceMap.hasKey(pkg):
        sandboxCfg.rebuiltConsumers.add(pkg)
        debug "buildAll: added rebuilt consumer " & pkg & " to rebuiltConsumers"
      for consumer in consumers:
        if consumer notin deps:
          try:
            let pkgDir = findPkgRepo(consumer) & "/" & consumer
            let rf = parseRunfile(pkgDir)
            for bdep in rf.bdeps:
              if bdep notin deps:
                deps.add(bdep)
                info "Added " & bdep & " (build dep) to queue for consumer " & consumer
          except:
            debug "could not resolve bdeps for consumer " & consumer
          deps.add(consumer)
          sonameSourceMap[consumer] = pkg
          sandboxCfg.ignoreUseCacheIfAvailable.add(consumer)
          info "Added " & consumer & " to build queue (SONAME consumer rebuild)"
    except CatchableError:
      when defined(release):
        fatal("Undefined error occured")
      else:
        raise getCurrentException()
    i.inc

  info("built all packages successfully")

  # Install SONAME-changed source packages to host after all consumers
  # are rebuilt. This provides the new library version (e.g. libssl.so.4)
  # that rebuilt consumers link against.
  for src in sonameSources:
    info "Installing SONAME-changed package '" & src & "' to host"
    installPkg(findPkgRepo(src), src, sandboxCfg.fullRootPath,
            manualInstallList = @[], kTarget = sandboxKTarget,
            isUpgrade = true, ignorePostInstall = true, umount = false)

  return 0
