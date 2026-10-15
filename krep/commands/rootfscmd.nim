import os
import times
import osproc
import sequtils
import strutils
import parsecfg
import posix_utils
import ../modules/commonProcs
import ../../common/logging
import ../../common/version
import ../../kpkg/commands/buildcmd
import ../../kpkg/commands/updatecmd
import ../../kpkg/commands/installcmd
import ../../kpkg/modules/commonTasks
import ../modules/resources
import ../../kpkg/modules/rootfs/config as rootfsConfig
import ../../kpkg/modules/rootfs/types as rootfsTypes
import ../../kpkg/modules/rootfs/plan as rootfsPlan
import ../../kpkg/modules/rootfs/finalize as rootfsFinalize
import ../../kpkg/modules/rootfs/state as rootfsState

## Kreato Linux's build tools.


proc initKrelease(config: rootfsTypes.RootfsConfig) =
  # Initialize kreato-release.

  var release = newConfig()

  release.setSectionKey("General", "dateBuilt", getDateStr())
  release.setSectionKey("General", "klinuxVersion", "rolling")
  release.setSectionKey("General", "srcCommit", commitVer)

  release.setSectionKey("Core", "libc", config.profile.libc)
  release.setSectionKey("Core", "compiler", config.profile.compiler)
  release.setSectionKey("Core", "coreutils", config.profile.coreutils)
  release.setSectionKey("Core", "tlsLibrary", config.profile.tlsLibrary)
  release.setSectionKey("Core", "init", config.profile.init)

  release.setSectionKey("Extras", "extraPackages",
      config.profile.extraPackages.join(" "))
  release.writeConfig(config.buildDirectory / "etc/kreato-release")

proc kreastrapInstall(package: string, installWithBinaries: bool,
        buildDir: string, useCacheIfPossible = true, target = kpkgTarget(
            buildDir),
        noSandbox = false) =
  # Install a package.
  info "Installing package '"&package&"'"

  var targetFin = target

  if targetFin == "default":
    targetFin = kpkgTarget(buildDir)

  if installWithBinaries == true:
    debug "Installing package as a binary"
    discard install(toSeq([package]), buildDir, true, target = targetFin,
            basePackage = true)
  else:
    debug "Building package from source"
    discard build(yes = true, root = "/", packages = toSeq([
            package]),
            useCacheIfAvailable = useCacheIfPossible,
            forceInstallAll = true, target = targetFin,
            noSandbox = noSandbox)
    discard install(toSeq([package]), buildDir, true, offline = true,
            target = targetFin, basePackage = true)

  ok("Package "&package&" installed successfully")

proc converterArch(arch: string): string =
  # Converts architectures to the different name.
  case arch:
    of "amd64":
      return "x86_64"
    of "arm64":
      return "aarch64"
    else:
      return arch

proc runRootfs*(buildType = "builder", arch = "amd64",
        useCacheIfPossible = true, noSandbox = false, dataDir = "",
        configPath = "", overlayPath = "") =
  ## Build a Kreato Linux rootfs.
  ##
  ## With noSandbox, every source build skips the kpkg sandbox and builds
  ## directly in the root it runs on. Use this when kreastrap itself runs
  ## inside a chroot or seed image (e.g. bootstrapping a foreign arch from a
  ## Ubuntu base): there is no kpkg environment or overlay stack to set up
  ## there, and the chroot is already the isolation boundary.

  if not isAdmin():
    fatal "You have to be root to continue."

  let invocationDir = getCurrentDir()
  defer:
    if dirExists(invocationDir):
      setCurrentDir(invocationDir)

  var typedConfig: rootfsTypes.RootfsConfig
  var target = "default"

  var resources: string
  try:
    resources = resolveResourceDir("rootfs", dataDir)
  except ValueError as exc:
    fatal exc.msg
  let configBase = resources / "arch" / arch / "configs" / buildType
  let configFile = if configPath.len > 0: absolutePath(configPath)
                   else: configBase & ".kg"
  let overlayDir = if overlayPath.len > 0: absolutePath(overlayPath)
                   else: resources / "overlay"
  if not fileExists(configFile):
    fatal("Config does not exist: " & configFile)
  if not configFile.endsWith(".kg"):
    fatal("Rootfs configuration must be a declarative Kongue .kg file: " &
        configFile)
  try:
    typedConfig = rootfsConfig.loadRootfsConfig(configFile)
  except CatchableError as exc:
    fatal("Invalid rootfs configuration: " & exc.msg)
  if overlayPath.len > 0 and not dirExists(overlayDir):
    fatal("Overlay does not exist: " & overlayDir)

  # kpkg can change cwd during updates and builds. Resolve the output path
  # once, against the caller's cwd, and keep kreato-release on that same path.
  let configuredBuildDir = typedConfig.buildDirectory
  if configuredBuildDir.len == 0:
    fatal("build_directory must not be empty")
  let buildDir = absolutePath(configuredBuildDir, invocationDir)
  typedConfig.buildDirectory = buildDir
  target = typedConfig.profile.target

  info "rootfs, built with commit "&commitVer

  discard update()

  debug "Architecture is set as "&arch
  debug "Build type is "&buildType

  if converterArch(arch) != uname().machine:
    info "cross-compiling to '"&arch&"'"

  initDirectories(buildDir, arch)

  if typedConfig.useOverlay and dirExists(overlayDir):
    info "Overlay found, installing contents"

    for kind, path in walkDir(overlayDir):
      case kind:
        of pcFile:
          debug "Adding the file '"&lastPathPart(
                  path)&"' to '"&buildDir&"/"&lastPathPart(path)&"'"
          copyFile(path, buildDir&"/"&lastPathPart(path))
        of pcDir:
          debug "Adding the directory '"&lastPathPart(
                  path)&"' to '"&buildDir&"/"&lastPathPart(path)&"'"
          copyDir(path, buildDir&"/"&lastPathPart(path))
        of pcLinkToFile:
          debug "Adding the symlinked file '"&lastPathPart(
                  path)&"' to '"&buildDir&"/"&lastPathPart(
                  path)&"' (will not follow symlink)"
          copyFile(path, buildDir&"/"&lastPathPart(path), options = {})
        of pcLinkToDir:
          debug "Adding the symlinked directory '"&lastPathPart(
                  path)&"' to '"&buildDir&"/"&lastPathPart(path)&"'"
          copyDir(path, buildDir&"/"&lastPathPart(path))

  var installWithBinaries: bool

  installWithBinaries = typedConfig.packageMode == rootfsTypes.pmBinary

  initKrelease(typedConfig)

  let exclusions: seq[string] = @[]
  let plan = rootfsPlan.makeRootfsPlan(typedConfig.profile,
      rootfsTypes.rmEmpty, exclusions = exclusions)
  rootfsState.writeRootfsState(buildDir / rootfsState.rootfsStateFile,
    rootfsTypes.RootfsState(schemaVersion: 1,
      status: rootfsTypes.rsProvisioning, target: typedConfig.profile.target,
      profileFingerprint: typedConfig.profile.fingerprint,
      rootMode: rootfsTypes.rmEmpty,
      acquisitionMode: if installWithBinaries: rootfsTypes.amBinariesOnly
        else: rootfsTypes.amBuildMissing,
      phase: rootfsTypes.rpAcquiring, profile: typedConfig.profile,
      packageRoots: plan.install, extraPackages: typedConfig.profile.extraPackages,
      pendingPackages: plan.install))

  var provisioningComplete = false
  defer:
    if not provisioningComplete and fileExists(buildDir /
        rootfsState.rootfsStateFile):
      try:
        var failed = rootfsState.loadRootfsState(buildDir /
            rootfsState.rootfsStateFile)
        failed.status = rootfsTypes.rsFailed
        failed.failureStage = $failed.phase
        rootfsState.writeRootfsState(buildDir /
            rootfsState.rootfsStateFile, failed)
      except CatchableError:
        discard

  # Binary mode acquires the complete closure before installation starts.
  if installWithBinaries and plan.acquire.len > 0:
    discard install(plan.acquire, buildDir, true, downloadOnly = true,
      target = target, basePackage = true)

  var completed: seq[string]
  for package in plan.install:
    var current = rootfsState.loadRootfsState(buildDir /
        rootfsState.rootfsStateFile)
    current.phase = rootfsTypes.rpInstalling
    current.pendingPackages = plan.install.filterIt(it notin completed)
    current.completedPackages = completed
    rootfsState.writeRootfsState(buildDir / rootfsState.rootfsStateFile, current)
    kreastrapInstall(package, installWithBinaries, buildDir,
        useCacheIfPossible, target, noSandbox)
    completed.add(package)

  if typedConfig.profile.compiler != "no":
    set_default_cc(buildDir, typedConfig.profile.compiler)
  rootfsFinalize.finalizeProfileLinks(buildDir, typedConfig.profile)

  # Finalizers run only after every package exists. A failed command leaves the
  # state provisioning, so an incomplete root can never be mistaken for ready.
  var finalizing = rootfsState.loadRootfsState(buildDir /
      rootfsState.rootfsStateFile)
  finalizing.phase = rootfsTypes.rpFinalizing
  finalizing.pendingPackages.setLen(0)
  finalizing.completedPackages = completed
  rootfsState.writeRootfsState(buildDir / rootfsState.rootfsStateFile, finalizing)

  setCurrentDir(getAppDir())
  let enableShadowedPw = execCmdEx("chroot "&buildDir&" /usr/sbin/pwconv")
  if enableShadowedPw.exitcode != 0:
    debug enableShadowedPw.output
    fatal "Enabling shadow failed"

  info "Generating CA certificates"
  let caCertCmd = execCmdEx("chroot "&buildDir&" /bin/sh -c 'update-ca-trust'")
  if caCertCmd.exitcode != 0:
    debug "CA certification generation output: "&caCertCmd.output
    fatal "Generating CA certificates failed"
  if fileExists(buildDir&"/certdata.txt"): removeFile(buildDir&"/certdata.txt")

  var ready = rootfsState.loadRootfsState(buildDir /
      rootfsState.rootfsStateFile)
  ready.status = rootfsTypes.rsReady
  ready.phase = rootfsTypes.rpComplete
  rootfsState.writeRootfsState(buildDir / rootfsState.rootfsStateFile, ready)
  provisioningComplete = true
