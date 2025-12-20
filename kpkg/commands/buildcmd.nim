import os
import posix
import sets
import tables
import times
import strutils
import sequtils
import parsecfg
import installcmd
import ../modules/sqlite
import ../modules/logger
import ../modules/config
import ../modules/lockfile
import ../modules/isolation
import ../modules/runparser
import ../modules/dephandler
import ../modules/commonTasks
import ../modules/commonPaths
import ../modules/builder/main
import ../modules/builder/sources
import ../modules/builder/packager
import ../modules/run3/executor
import ../modules/run3/run3

#import ../modules/crossCompilation

# proc fakerootWrap removed - replaced by run3 executor

proc builder*(package: string, destdir: string, offline = false,
            dontInstall = false, useCacheIfAvailable = false,
                    tests = false, manualInstallList: seq[string],
                            customRepo = "", isInstallDir = false,
                            isUpgrade = false, target = "default",
                            actualRoot = "default", ignorePostInstall = false,
                            noSandbox = false, ignoreTarget = false,
                            ignoreUseCacheIfAvailable = @[""],
                            isBootstrap = false): bool =
  ## Builds the packages.

  debug "builder ran, package: '"&package&"', destdir: '"&destdir&"' root: '"&kpkgSrcDir&"', useCacheIfAvailable: '"&(
          $useCacheIfAvailable)&"'"


  preliminaryChecks(target, actualRoot)

  # Actual building start here

  var repo: string

  if not isEmptyOrWhitespace(customRepo):
    debug "customRepo set to: '"&customRepo&"'"
    repo = "/etc/kpkg/repos/"&customRepo
  else:
    debug "customRepo not set"
    repo = findPkgRepo(package)

  var path: string

  if not dirExists(package) and isInstallDir:
    err("package directory doesn't exist", false)

  if isInstallDir:
    debug "isInstallDir is turned on"
    path = absolutePath(package)
    repo = path.parentDir()
  else:
    path = repo&"/"&package

  if not fileExists(path&"/run") and not fileExists(path&"/run3"):
    err("runFile/run3File doesn't exist, cannot continue", false)

  var actualPackage: string

  if isInstallDir:
    actualPackage = lastPathPart(package)
  else:
    actualPackage = package

  # Remove directories if they exist
  removeDir(kpkgBuildRoot)
  removeDir(kpkgSrcDir)

  let arch = getArch(target)
  let kTarget = getKtarget(target, destdir)

  initEnv(actualPackage, kTarget)

  # Enter into the source directory
  setCurrentDir(kpkgSrcDir)

  var pkg: runFile
  try:
    debug "parseRunfile ran from buildcmd"
    pkg = runparser.parseRunfile(path)
  except CatchableError:
    err("Unknown error while trying to parse package on repository, possibly broken repo?", false)

  var override: Config

  if fileExists("/etc/kpkg/override/"&package&".conf"):
    override = loadConfig("/etc/kpkg/override/"&package&".conf")
  else:
    override = newConfig() # So we don't get storage access errors

  if fileExists(kpkgArchivesDir&"/system/"&kTarget&"/"&actualPackage&"-"&pkg.versionString&".kpkg") and
          useCacheIfAvailable == true and dontInstall == false and not (
          actualPackage in ignoreUseCacheIfAvailable):

    debug "Tarball (and the sum) already exists, going to install"
    if destdir != "/" and target == "default":
      installPkg(repo, actualPackage, "/", pkg, manualInstallList,
              ignorePostInstall = ignorePostInstall) # Install package on root too

    if kTarget == kpkgTarget(destDir):
      installPkg(repo, actualPackage, destdir, pkg, manualInstallList,
              ignorePostInstall = ignorePostInstall)
    else:
      info "the package target doesn't match the one on '"&destDir&"', skipping installation"
    removeDir(kpkgBuildRoot)
    removeDir(kpkgSrcDir)
    removeLockfile()
    return true

  debug "Tarball (and the sum) doesn't exist, going to continue"

  if pkg.isGroup:
    debug "Package is a group package"
    installPkg(repo, actualPackage, destdir, pkg, manualInstallList,
            ignorePostInstall = ignorePostInstall)
    removeDir(kpkgBuildRoot)
    removeDir(kpkgSrcDir)
    removeLockfile()
    return true

  createDir(kpkgTempDir2)

  var exists = (
          prepare: false,
          package: false,
          check: false,
          packageInstall: false,
          packageBuild: false,
          build: false
    )

  for i in pkg.functions:
    debug "now checking out '"&i.name&"'"
    case i.name
    of "prepare":
      exists.prepare = true
    of "package":
      exists.package = true
    of "check":
      exists.check = true
    of "build":
      exists.build = true

    if "package_"&replace(actualPackage, '-', '_') == i.name:
      exists.packageInstall = true

    if "build_"&replace(actualPackage, '-', '_') == i.name:
      exists.packageBuild = true


  var folder: string

  sourceDownloader(pkg, actualPackage, kpkgSrcDir, path)

  setFilePermissions(kpkgSrcDir, {fpUserExec, fpUserWrite, fpUserRead,
          fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})
  discard posix.chown(cstring(kpkgSrcDir), 999, 999)

  var amountOfFolders: int

  for i in toSeq(walkDir(".")):
    debug i.path
    if dirExists(i.path):
      folder = absolutePath(i.path)
      amountOfFolders = amountOfFolders + 1
      setFilePermissions(folder, {fpUserExec, fpUserWrite, fpUserRead,
              fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})
    discard posix.chown(cstring(folder), 999, 999)
    for i in toSeq(walkDirRec(folder, {pcFile, pcLinkToFile, pcDir,
            pcLinkToDir})):
      discard posix.chown(cstring(i), 999, 999)

  # Track the actual source directory for run3 context
  # Default to kpkgSrcDir, update to autocd folder if applicable
  var actualSrcDir = kpkgSrcDir

  if amountOfFolders == 1 and (not isEmptyOrWhitespace(folder)):
    try:
      # autocd
      setCurrentDir(folder)
      actualSrcDir = folder
    except Exception:
      when defined(release):
        err("Unknown error occured while trying to enter the source directory")

      debug $folder
      raise getCurrentException()

  # Determine environment variables for Run3 context
  var envVars = initTable[string, string]()
  var cc = getConfigValue("Options", "cc", "cc")
  var cxx = getConfigValue("Options", "cxx", "c++")

  var actTarget: string
  let tSplit = target.split("-")
  if tSplit.len >= 4:
    actTarget = tSplit[0]&"-"&tSplit[1]&"-"&tSplit[2]
  else:
    actTarget = target

  if isBootstrap:
    envVars["KPKG_BOOTSTRAP"] = "1"

  envVars["KPKG_ARCH"] = arch
  envVars["KPKG_TARGET"] = actTarget
  envVars["KPKG_HOST_TARGET"] = systemTarget(actualRoot)

  if not (actTarget != "default" and actTarget != systemTarget("/")):
    envVars.del("KPKG_HOST_TARGET") # Unset if default

  if parseBool(override.getSectionValue("Other", "ccache", getConfigValue(
          "Options", "ccache", "false"))) and packageExists("ccache"):
    if not dirExists(kpkgCacheDir&"/ccache"):
      createDir(kpkgCacheDir&"/ccache")
    setFilePermissions(kpkgCacheDir&"/ccache", {fpUserExec, fpUserWrite,
            fpUserRead, fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})
    discard posix.chown(cstring(kpkgCacheDir&"/ccache"), 999, 999)

    envVars["CCACHE_DIR"] = kpkgCacheDir&"/ccache"
    envVars["PATH"] = "/usr/lib/ccache:" & getEnv("PATH")

  if actTarget == "default" or actTarget == systemTarget("/"):
    envVars["CC"] = cc
    envVars["CXX"] = cxx

  if not isEmptyOrWhitespace(override.getSectionValue("Flags",
          "extraArguments")):
    envVars["KPKG_EXTRA_ARGUMENTS"] = override.getSectionValue("Flags", "extraArguments")

  envVars["SRCDIR"] = kpkgSrcDir
  envVars["PACKAGENAME"] = actualPackage

  let cxxflags = override.getSectionValue("Flags", "cxxflags", getConfigValue(
          "Options", "cxxflags"))
  if not isEmptyOrWhitespace(cxxflags):
    envVars["CXXFLAGS"] = cxxflags

  let cflags = override.getSectionValue("Flags", "cflags", getConfigValue(
          "Options", "cflags"))
  if not isEmptyOrWhitespace(cflags):
    envVars["CFLAGS"] = cflags

  # Prepare Context
  # We use kpkgBuildRoot as destDir for build steps
  # We use actualSrcDir (autocd folder or kpkgSrcDir) as srcDir
  # We use kpkgBuildRoot as buildRoot
  let ctx = initFromRunfile(pkg.run3Data.parsed, destDir = kpkgBuildRoot,
          srcDir = actualSrcDir, buildRoot = kpkgBuildRoot)

  # Apply environment variables
  for k, v in envVars:
    ctx.envVars[k] = v

  ctx.passthrough = noSandbox

  # Execute "prepare"
  if exists.prepare:
    if executeRun3Function(ctx, pkg.run3Data.parsed, "prepare") != 0:
      err("prepare failed", true)

  # Determine "build" function name
  var buildFunc = "build"
  if exists.packageBuild:
    buildFunc = "build_" & replace(actualPackage, '-', '_')
  elif not exists.build:
    buildFunc = "" # true
    
    # Determine "package" function name
  var pkgFunc = "package"
  if exists.packageInstall:
    pkgFunc = "package_" & replace(actualPackage, '-', '_')
  elif not exists.package:
    err "install stage of package doesn't exist, invalid runfile"

  # Execute build
  if buildFunc != "":
    if executeRun3Function(ctx, pkg.run3Data.parsed, buildFunc) != 0:
      err("build failed", true)

  # Execute check (tests)
  if tests and exists.check:
    if executeRun3Function(ctx, pkg.run3Data.parsed, "check") != 0:
      # checks usually fail build
      err("check failed", true)

  # Execute package (install)
  if executeRun3Function(ctx, pkg.run3Data.parsed, pkgFunc) != 0:
    err("package install failed", true)

  discard createPackage(actualPackage, pkg, kTarget)

  # Install package to root aswell so dependency errors doesnt happen
  # because the dep is installed to destdir but not root.
  if destdir != "/" and not packageExists(actualPackage) and (
          not dontInstall) and target == "default":
    installPkg(repo, actualPackage, "/", pkg, manualInstallList,
            isUpgrade = isUpgrade, ignorePostInstall = ignorePostInstall)

  if (not dontInstall) and (kTarget == kpkgTarget(destDir)):
    installPkg(repo, actualPackage, destdir, pkg, manualInstallList,
            isUpgrade = isUpgrade, ignorePostInstall = ignorePostInstall)
  else:
    info "the package target doesn't match the one on '"&destDir&"', skipping installation"

  removeLockfile()

  when defined(release):
    removeDir(kpkgSrcDir)
    removeDir(kpkgTempDir2)

  return false

proc build*(no = false, yes = false, root = "/",
    packages: seq[string],
            useCacheIfAvailable = true, forceInstallAll = false,
                    dontInstall = false, tests = true,
                            ignorePostInstall = false, isInstallDir = false,
                            isUpgrade = false, target = "default",
                            bootstrap = false): int =
  ## Build and install packages.
  let init = getInit(root)
  var deps: seq[string]
  var depGraph: dependencyGraph
  var gD: seq[string]

  if packages.len == 0:
    err("please enter a package name", false)

  var fullRootPath = expandFilename(root)
  var ignoreInit = false

  #if target != "default":
  #    if not crossCompilerExists(target):
  #        err "cross-compiler for '"&target&"' doesn't exist, please build or install it (see handbook/cross-compilation)"

  #    fullRootPath = root&"/usr/"&target
  #    ignoreInit = true

  var allDependents: seq[string]

  try:
    # Build the dependency graph once
    (deps, depGraph) = dephandlerWithGraph(packages, isBuild = true,
            root = fullRootPath, forceInstallAll = forceInstallAll,
            isInstallDir = isInstallDir, ignoreInit = ignoreInit,
            useBootstrap = bootstrap,
            useCacheIfAvailable = useCacheIfAvailable)

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
              useCacheIfAvailable = useCacheIfAvailable)
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
    for p in packages:
      pkgPaths[lastPathPart(p)] = absolutePath(p)

  for i in deps:
    try:
      createOrUpgradeEnv(root)

      let pkgTmp = parsePkgInfo(i)

      # Extract sandbox dependencies from the graph we already built
      # This avoids re-parsing runfiles and recalculating dependencies
      let sandboxDeps = getSandboxDepsFromGraph(pkgTmp.name, depGraph,
              bootstrap, fullRootPath, forceInstallAll, isInstallDir, ignoreInit)

      debug "sandboxDeps for "&pkgTmp.name&" = \""&sandboxDeps.join(" ")&"\""
      var allInstalledDeps: seq[string]

      # Prepare overlay directories first (mount tmpfs and create directory structure)
      discard prepareOverlayDirs(error = "preparing overlay directories")

      if target != "default" and target != kpkgTarget("/"):
        for d in sandboxDeps:
          if isEmptyOrWhitespace(d):
            continue

          debug "build: installPkg ran for '"&d&"'"
          installPkg(findPkgRepo(d), d, kpkgOverlayPath&"/upperDir",
                  isUpgrade = false, kTarget = target,
                  manualInstallList = @[], umount = false,
                  disablePkgInfo = true)
      else:
        # Collect all transitive runtime dependencies from the graph for postinstall
        var visited = initHashSet[string]()
        allInstalledDeps = deduplicate(collectRuntimeDepsFromGraph(
                sandboxDeps, depGraph, visited))

        # Install build dependencies to upperDir (now on tmpfs, before overlay mount)
        for d in sandboxDeps:
          discard installFromRoot(d, root,
                  kpkgOverlayPath&"/upperDir",
                  ignorePostInstall = true)

      # Now mount the overlayfs after build dependencies are installed
      discard mountOverlayFilesystem(
              error = "mounting overlay filesystem")

      # Now run postinstall scripts for all build dependencies (including transitive) in the merged overlay
      # Only for native builds (cross-compilation uses different mechanism)
      if target == "default" or target == kpkgTarget("/"):
        debug "builder-ng: postinstall is running"
        for d in deduplicate(allInstalledDeps):
          if not isEmptyOrWhitespace(d):
            runPostInstall(d)

      let packageSplit = parsePkgInfo(i)

      # Determine if this is a bootstrap build from the graph
      let isBootstrapBuild = bootstrap and depGraph.nodes.hasKey(
              pkgTmp.name) and depGraph.nodes[
              pkgTmp.name].metadata.bsdeps.len > 0

      var customRepo = ""
      var isInstallDirFinal: bool
      var pkgName: string

      # Try to get repo from graph first
      if depGraph.nodes.hasKey(pkgTmp.name):
        let r = depGraph.nodes[pkgTmp.name].repo
        if r != "local" and r.startsWith("/etc/kpkg/repos/"):
          customRepo = lastPathPart(r)

      if isInstallDir and pkgPaths.hasKey(pkgTmp.name):
        pkgName = pkgPaths[pkgTmp.name]
        isInstallDirFinal = true
      else:
        if "/" in packageSplit.nameWithRepo:
          customRepo = lastPathPart(packageSplit.repo)
          pkgName = packageSplit.name
        else:
          pkgName = packageSplit.name

      if isBootstrapBuild:
        info("Performing bootstrap build for "&i)

      discard builder(pkgName, fullRootPath, offline = false,
              dontInstall = dontInstall,
              useCacheIfAvailable = useCacheIfAvailable, tests = tests,
              manualInstallList = p, customRepo = customRepo,
              isInstallDir = isInstallDirFinal, isUpgrade = isUpgrade,
              target = target, actualRoot = root,
              ignorePostInstall = ignorePostInstall,
              ignoreUseCacheIfAvailable = gD,
              isBootstrap = isBootstrapBuild)

      success("built "&i&" successfully")
    except CatchableError:
      when defined(release):
        err("Undefined error occured", true)
      else:
        raise getCurrentException()

  success("built all packages successfully")
  return 0
