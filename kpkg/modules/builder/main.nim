#[
This module is the main module for the builder-ng module.
]#
import os
import strutils
import parsecfg
import ./types
import ../config
import ../logger
import ../lockfile
import posix_utils
import ../processes
import ../runparser
import ../commonPaths
import ../commonTasks

proc cleanUp*() {.noconv.} =
  ## Cleans up.
  debug "builder-ng: clean up"
  removeLockfile()
  quit(0)

proc getArch*(target: string): string =
  var arch: string

  if target != "default":
    arch = target.split("-")[0]
  else:
    arch = uname().machine

  if arch == "amd64":
    arch = "x86_64" # For compatibility

  debug "arch: '"&arch&"'"

  return arch


proc getKtarget*(target: string, destDir: string): string =
  var kTarget: string

  if target != "default":

    if target.split("-").len != 3 and target.split("-").len != 5:
      error("target '"&target&"' invalid")
      quit(1)

    if target.split("-").len == 5:
      kTarget = target
    else:
      kTarget = kpkgTarget(destDir, target)
  else:
    kTarget = kpkgTarget(destDir)

  debug "kpkgTarget: '"&kTarget&"'"

  return kTarget



proc preliminaryChecks*(target: string, actualRoot: string) =
  #[
    This function includes the following checks:
        - is root (isAdmin)
        - is kpkg running (isKpkgRunning)
        - does lockfile exist (checkLockfile)
        - set control-c hook (setControlCHook)

    If any of these checks fail, the program will exit.
    ]#
    
    # TODO: have an user mode for this
  if not isAdmin():
    error("you have to be root for this action.")
    quit(1)

  if target != "default" and actualRoot == "default":
    fatal("internal error: actualRoot needs to be set when target is used (please open a bug report)")

  isKpkgRunning()
  checkLockfile()

  setControlCHook(cleanUp)


proc initEnv*(actualPackage: string, kTarget: string) =
  #[
    This function initializes the environment for the build process.

    This includes:
        - Creating the environment
        - Mounting the overlay filesystem

    If any of these checks fail, the program will exit.
    ]#
  debug "builder-ng: initEnv"

  # Create tarball directory if it doesn't exist
  discard existsOrCreateDir("/var/cache")
  discard existsOrCreateDir(kpkgCacheDir)
  discard existsOrCreateDir(kpkgArchivesDir)
  discard existsOrCreateDir(kpkgSourcesDir)
  discard existsOrCreateDir(kpkgSourcesDir&"/"&actualPackage)
  discard existsOrCreateDir(kpkgArchivesDir&"/system")
  discard existsOrCreateDir(kpkgArchivesDir&"/system/"&kTarget)

  # Create required directories
  createDir(kpkgBuildRoot)
  createDir(kpkgSrcDir)

  setFilePermissions(kpkgBuildRoot, {fpUserExec, fpUserWrite, fpUserRead,
          fpGroupExec, fpGroupWrite, fpGroupRead,
          fpOthersExec, fpOthersWrite, fpOthersRead})
  setFilePermissions(kpkgSrcDir, {fpOthersWrite, fpOthersRead, fpOthersExec})

  createLockfile()
  debug "builder-ng: initEnv done"


proc loadOverrideConfig*(package: string): Config =
  ## Loads override config from /etc/kpkg/override/{package}.conf
  ##
  ## Returns empty Config if file doesn't exist.

  if fileExists("/etc/kpkg/override/" & package & ".conf"):
    return loadConfig("/etc/kpkg/override/" & package & ".conf")
  else:
    return newConfig()


proc handleGroupPackage*(pkg: runFile, repo: string, actualPackage: string,
                         destdir: string, manualInstallList: seq[string],
                         ignorePostInstall: bool,
                         installPkgProc: proc(repo: string, package: string,
                                              root: string, runf: runFile,
                                              manualInstallList: seq[string],
                                              ignorePostInstall: bool)): bool =
  ## Handles group package installation.
  ##
  ## Parameters:
  ##   pkg: Parsed runfile
  ##   repo: Repository path
  ##   actualPackage: Package name
  ##   destdir: Destination directory
  ##   manualInstallList: List of manually installed packages
  ##   ignorePostInstall: Whether to ignore postinstall scripts
  ##   installPkgProc: Callback to installPkg (avoids circular import)
  ##
  ## Returns true if package is a group (caller should return early).
  ## Performs cleanup on completion.

  if not pkg.isGroup:
    return false

  debug "Package is a group package"
  installPkgProc(repo, actualPackage, destdir, pkg, manualInstallList,
                 ignorePostInstall)
  removeDir(kpkgBuildRoot)
  removeDir(kpkgSrcDir)
  removeLockfile()
  return true


proc resolveSourceDir*(pkg: runFile, baseDir: string,
                       folder: string, amountOfFolders: int): string =
  ## Determines actual source directory based on autocd setting.
  ##
  ## Parameters:
  ##   pkg: Parsed runfile
  ##   baseDir: Base source directory (kpkgSrcDir)
  ##   folder: Path to the single folder found (if any)
  ##   amountOfFolders: Number of folders in baseDir
  ##
  ## Returns folder if autocd enabled and single folder exists,
  ## otherwise returns baseDir.

  if pkg.autocd and amountOfFolders == 1 and (not isEmptyOrWhitespace(folder)):
    try:
      setCurrentDir(folder)
      return folder
    except Exception:
      when defined(release):
        fatal("Unknown error occured while trying to enter the source directory")
      debug $folder
      raise getCurrentException()

  return baseDir


proc resolvePaths*(cfg: var BuildConfig, customRepo: string) =
  ## Resolves repository and package paths based on configuration.
  ##
  ## Modifies cfg in place to set repo, path, and actualPackage.

  if not isEmptyOrWhitespace(customRepo):
    debug "customRepo set to: '" & customRepo & "'"
    cfg.repo = "/etc/kpkg/repos/" & customRepo
  else:
    debug "customRepo not set"
    cfg.repo = findPkgRepo(cfg.package)

  if not dirExists(cfg.package) and cfg.isInstallDir:
    error("package directory doesn't exist")
    quit(1)

  if cfg.isInstallDir:
    debug "isInstallDir is turned on"
    cfg.path = absolutePath(cfg.package)
    cfg.repo = cfg.path.parentDir()
  else:
    cfg.path = cfg.repo & "/" & cfg.package

  if not fileExists(cfg.path & "/run") and not fileExists(cfg.path & "/run3"):
    error("runFile/run3File doesn't exist, cannot continue")
    quit(1)

  if cfg.isInstallDir:
    cfg.actualPackage = lastPathPart(cfg.package)
  else:
    cfg.actualPackage = cfg.package


proc initBuildState*(cfg: BuildConfig): BuildState =
  ## Initializes build state by parsing runfile.
  ##
  ## Returns BuildState with parsed package info.

  var pkg: runFile
  try:
    debug "parseRunfile ran from builder"
    pkg = runparser.parseRunfile(cfg.path)
  except CatchableError:
    error("Unknown error while trying to parse package on repository, possibly broken repo?")
    quit(1)

  result = BuildState(
    pkg: pkg,
    exists: BuildFunctions(),
    amountOfFolders: 0,
    folder: ""
  )
