# Module for isolating kpkg builds as much as possible
import std/os
import ../../common/logging
import sqlite
import std/times
import processes
import dephandler
import runparser
import commonPaths
import commonTasks
import std/sequtils
import std/strutils
import std/parsecfg
import ../modules/config
import ../commands/checkcmd
import ../../kreastrap/commonProcs
import ../modules/run3/executor
import ../modules/run3/run3

# execEnv is now in processes.nim to avoid circular imports
export processes.execEnv


proc runPostInstall*(package: string, rootPath = kpkgMergedPath) =
  ## Runs postinstall scripts for a package in the provided environment root.
  ## Defaults to the merged overlay, but can be overridden (e.g. createEnv).
  debug "runPostInstall ran, package: '"&package&"', root: '"&rootPath&"'"
  let silent = not isEnabled(lvlDebug)
  debug "runPostInstall: finding repo for '"&package&"'"
  let repo = findPkgRepo(package)

  if isEmptyOrWhitespace(repo):
    return # bail early if no repo is found

  debug "runPostInstall: repo found: '"&repo&"'"
  let remountNeeded = (rootPath == kpkgMergedPath)

  # Run3 update
  var pkg: runFile
  debug "runPostInstall: parsing runfile"
  try:
    pkg = runparser.parseRunfile(repo&"/"&package)
  except CatchableError:
    warn("Could not parse runfile for " & package & " during postinstall")
    return

  debug "runPostInstall: initializing context"
  let ctx = initFromRunfile(pkg.run3Data.parsed, destDir = rootPath,
          srcDir = repo&"/"&package, buildRoot = rootPath)
  ctx.sandboxPath = rootPath
  ctx.remount = remountNeeded
  ctx.silent = silent
  ctx.asRoot = true # Postinstall scripts need root to modify system directories in sandbox

  debug "runPostInstall: checking for postinstall function"
  var postinstallFunc = ""
  if pkg.run3Data.parsed.hasFunction("postinstall_"&replace(package, '-', '_')):
    postinstallFunc = "postinstall_"&replace(package, '-', '_')
  elif pkg.run3Data.parsed.hasFunction("postinstall"):
    postinstallFunc = "postinstall"

  debug "runPostInstall: "&package&": postinstallFunc: "&postinstallFunc

  if postinstallFunc != "":
    if executeRun3Function(ctx, pkg.run3Data.parsed, postinstallFunc) != 0:
      fatal("postinstall failed on sandbox")


proc installFromRootInternal(package, root, destdir: string,
        removeDestdirOnError = false, ignorePostInstall = false) =

  debug "installFromRootInternal: package: \""&package&"\", root: \""&root&"\", destdir: \""&destdir&"\", removeDestdirOnError: \""&(
          $removeDestdirOnError)&"\", ignorePostInstall: \""&(
          $ignorePostInstall)&"\""

  # Check if package exists and has the right checksum
  check(package, root, true)

  let listFiles = getListFiles(package, root)

  for line in listFiles:
    let listFilesSplitted = line.split("=")[0].replace("\"", "")

    if not (fileExists(root&"/"&listFilesSplitted) or dirExists(
            root&"/"&listFilesSplitted)):
      #debug "file: \""&listFilesSplitted&"\", package: \""&package&"\""
      when defined(release):
        info "removing unfinished environment"
        removeDir(destdir)
        error("package \""&package&"\" has a broken symlink/invalid file structure, please reinstall the package")
        quit(1)

    if dirExists(root&"/"&listFilesSplitted) and not symlinkExists(
            root&"/"&listFilesSplitted):
      let dirPath = destdir&"/"&relativePath(root&"/"&listFilesSplitted, root)
      #debug "Installing directory: "&listFilesSplitted
      createDirWithPermissionsAndOwnership(root&"/"&listFilesSplitted, dirPath)
      continue

    discard existsOrCreateDir(destdir)

    if fileExists(root&"/"&listFilesSplitted):
      let dirPath = destdir&"/"&relativePath(
              root&"/"&listFilesSplitted.parentDir(), root)

      if not dirExists(dirPath):
        createDirWithPermissionsAndOwnership(
                root&"/"&listFilesSplitted.parentDir(), dirPath)

      #debug "Installing file: "&listFilesSplitted
      copyFileWithPermissionsAndOwnership(root&"/"&listFilesSplitted,
              destdir&"/"&relativePath(listFilesSplitted, root))
  newPackageFromRoot(root, package, destdir)

  if ignorePostInstall:
    return

  runPostInstall(package, destdir)



proc installFromRoot*(package, root, destdir: string,
        removeDestdirOnError = false, ignorePostInstall = false): seq[string] =
  # A wrapper for installFromRootInternal that also resolves dependencies.
  if isEmptyOrWhitespace(package):
    return

  let depsUsed = deduplicate(dephandler(@[package], root = root,
          chkInstalledDirInstead = true, forceInstallAll = true)&package)
  for dep in depsUsed:

    if isEmptyOrWhitespace(dep):
      continue

    try:
      installFromRootInternal(dep, root, destdir, removeDestdirOnError, ignorePostInstall)
    except:
      if removeDestdirOnError:
        info "removing unfinished environment"
        removeDir(destdir)

      when defined(release):
        error("undefined error, please open an issue")
        quit(1)
      else:
        raise getCurrentException()
  return depsUsed

proc createEnvCtrlC() {.noconv.} =
  info "removing unfinished environment"
  removeDir(kpkgEnvPath)
  quit()


proc checkEnvPackageUpdates(name: string): bool =
  ## Checks package updates on the environment.
  let localPkgVer = getPackage(name, kpkgEnvPath).version
  let repo = findPkgRepo(name)
  let remotePkgVer = runparser.parseRunfile(repo&"/"&name).versionString

  if localPkgVer != remotePkgVer:
    return true
  else:
    return false


proc createEnv(root: string, ignorePostInstall = false) =
  # TODO: cross-compilation support
  info "initializing sandbox, this might take a while..."
  setControlCHook(createEnvCtrlC)
  initDirectories(kpkgEnvPath, hostCPU, true)

  copyFileWithPermissionsAndOwnership(root&"/etc/kreato-release",
          kpkgEnvPath&"/etc/kreato-release")

  var depsTotal: seq[string]

  let dict = loadConfig(kpkgEnvPath&"/etc/kreato-release")

  discard installFromRoot(dict.getSectionValue("Core", "libc"), root,
          kpkgEnvPath, ignorePostInstall = true)
  let compiler = dict.getSectionValue("Core", "compiler")
  if compiler == "clang":
    depsTotal.add installFromRoot("llvm", root, kpkgEnvPath,
            ignorePostInstall = true)
  else:
    depsTotal.add installFromRoot(compiler, root, kpkgEnvPath,
            ignorePostInstall = true)

  try:
    setDefaultCC(kpkgEnvPath, compiler)
  except:
    removeDir(root)
    when defined(release):
      error("setting default compiler in the environment failed")
      quit(1)
    else:
      raise getCurrentException()

  case dict.getSectionValue("Core", "coreutils"):
    of "gnu":
      for i in ["gnu-coreutils", "pigz", "xz-utils", "bash", "gsed",
              "bzip2", "patch", "diffutils", "findutils", "util-linux",
              "bc", "cpio", "which"]:
        depsTotal.add installFromRoot(i, root, kpkgEnvPath,
                ignorePostInstall = true)
      #installFromRoot("gnu-core", root, kpkgEnvPath, ignorePostInstall = true)
    of "busybox":
      depsTotal.add installFromRoot("busybox", root, kpkgEnvPath,
              ignorePostInstall = true)

  depsTotal.add installFromRoot(dict.getSectionValue("Core", "tlsLibrary"),
          root, kpkgEnvPath, ignorePostInstall = true)

  case dict.getSectionValue("Core", "init"):
    of "systemd":
      depsTotal.add installFromRoot("systemd", root, kpkgEnvPath,
              ignorePostInstall = true)
      depsTotal.add installFromRoot("dbus", root, kpkgEnvPath,
              ignorePostInstall = true)
    else:
      depsTotal.add installFromRoot(dict.getSectionValue("Core", "init"),
              root, kpkgEnvPath, ignorePostInstall = true)

  depsTotal.add installFromRoot(dict.getSectionValue("Core", "init"), root,
          kpkgEnvPath, ignorePostInstall = true)

  for i in "kreato-fs-essentials git kpkg ca-certificates python python-pip gmake".split(" "):
    depsTotal.add installFromRoot(i, root, kpkgEnvPath,
            ignorePostInstall = true)


  #let extras = dict.getSectionValue("Extras", "extraPackages").split(" ")

  #if not isEmptyOrWhitespace(extras.join("")):
  #    for i in extras:
  #        installFromRoot(i, root, kpkgEnvPath)

  let result = execCmdKpkg("bwrap --bind "&kpkgEnvPath&" / --bind /etc/resolv.conf /etc/resolv.conf /usr/bin/env update-ca-trust",
          silentMode = false)
  if result.exitCode != 0:
    debug "bwrap update-ca-trust failed with exit code: " & $result.exitCode
    debug "bwrap output: " & result.output
    removeDir(kpkgEnvPath)
    error("creating sandbox environment failed")
    quit(1)

  writeFile(kpkgEnvPath&"/envDateBuilt", now().format("yyyy-MM-dd"))

  if ignorePostInstall == false:
    runPostInstall(dict.getSectionValue("Core", "libc"), kpkgEnvPath)
    for dep in deduplicate(depsTotal):
      if isEmptyOrWhitespace(dep):
        continue
      runPostInstall(dep, kpkgEnvPath)


proc umountOverlay*(error = "none", silentMode = false, merged = kpkgMergedPath,
        upperDir = kpkgOverlayPath&"/upperDir",
        workDir = kpkgOverlayPath&"/workDir"): int =
  ## Unmounts the overlay.
  if not dirExists(merged) or not dirExists(kpkgOverlayPath) or not dirExists(workDir):
    return 0
  closeDb()
  let returnCode = execCmdKpkg("umount "&merged, error, silentMode).exitCode
  discard execCmdKpkg("umount "&kpkgOverlayPath, error,
          silentMode = silentMode)
  removeDir(merged)
  removeDir(upperDir)
  removeDir(workDir)
  return returnCode


proc createOrUpgradeEnv*(root: string, ignorePostInstall = false) =
  ## Creates and upgrades environment (if needed)

  if fileExists(kpkgEnvPath&"/etc/kreato-release"):
    try:
      var needsReinit = false
      let envPkgList = getListPackages(kpkgEnvPath)

      for pkg in envPkgList:
        if checkEnvPackageUpdates(pkg):
          debug "upgradeEnv: base package '"&pkg&"' is mismatching with the system, reinitializing environment"
          needsReinit = true

      if not needsReinit:
        return

    except:
      debug "upgradeEnv: something failed, reinitializing anyway"

  let umountExit = umountOverlay()
  if umountExit != 0:
    debug "createOrUpgradeEnv: umountOverlay failed, exit code "&($umountExit)
  removeDir(kpkgEnvPath)
  createEnv(root, ignorePostInstall)


proc prepareOverlayDirs*(upperDir = kpkgOverlayPath&"/upperDir",
        workDir = kpkgOverlayPath&"/workDir", merged = kpkgMergedPath,
        error = "none", silentMode = false): int =
  ## Prepares the overlay directories by mounting tmpfs and creating directory structure
  ## without mounting the overlayfs itself. This allows installing build dependencies
  ## before the overlay is mounted.
  try:
    removeDir(kpkgOverlayPath)
  except:
    discard umountOverlay(error, silentMode, merged, upperDir, workDir)
    removeDir(kpkgOverlayPath)

  createDir(kpkgOverlayPath)
  discard execCmdKpkg("mount -t tmpfs tmpfs "&kpkgOverlayPath, error,
          silentMode = silentMode)

  removeDir(upperDir)
  removeDir(merged)
  removeDir(workDir)
  createDir(upperDir)
  createDir(merged)
  createDir(workDir)

  initDirectories(upperDir, hostCPU, true)
  return 0

proc mountOverlayFilesystem*(upperDir = kpkgOverlayPath&"/upperDir",
        workDir = kpkgOverlayPath&"/workDir", lowerDir = kpkgEnvPath,
        merged = kpkgMergedPath, error = "none", silentMode = false): int =
  ## Mounts the overlayfs. Should be called after prepareOverlayDirs() and after
  ## installing build dependencies to upperDir.
  let cmd = "mount -t overlay overlay -o lowerdir="&lowerDir&",upperdir="&upperDir&",workdir="&workDir&" "&merged
  debug cmd
  return execCmdKpkg(cmd, error, silentMode = silentMode).exitCode

proc mountOverlay*(upperDir = kpkgOverlayPath&"/upperDir",
        workDir = kpkgOverlayPath&"/workDir", lowerDir = kpkgEnvPath,
        merged = kpkgMergedPath, error = "none", silentMode = false): int =
  ## Mounts the overlay in one step (prepare directories and mount overlayfs).
  ## For build processes that need to install dependencies before mounting,
  ## use prepareOverlayDirs() and mountOverlayFilesystem() separately.
  discard prepareOverlayDirs(upperDir, workDir, merged, error, silentMode)
  return mountOverlayFilesystem(upperDir, workDir, lowerDir, merged, error, silentMode)
