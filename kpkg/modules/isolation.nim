# Module for isolating kpkg builds as much as possible
import std/os
import ../../common/logging
import sqlite
import envstate
from libarchive import isArchiveRootMetadata
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
import ../../krep/modules/commonProcs
import ../modules/run3/run3

# execEnv is now in processes.nim to avoid circular imports
export processes.execEnv


proc runPostInstall*(package: string, rootPath = kpkgMergedPath,
        passthrough = false) =
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
  let ctx = initRun3ContextFromParsed(pkg.run3Data.parsed, destDir = rootPath,
          srcDir = repo&"/"&package, buildRoot = rootPath)
  ctx.sandboxPath = rootPath
  ctx.remount = remountNeeded
  ctx.silent = silent
  # Passthrough runs the postinstall directly on rootPath (no bwrap/overlay
  # needed). This is how noSandbox builds run postinstalls on a chroot root.
  ctx.passthrough = passthrough
  ctx.asRoot = true # Postinstall scripts need root to modify system directories in sandbox

  debug "runPostInstall: checking for postinstall function"
  var postinstallFunc = ""
  if pkg.run3Data.parsed.hasFunction("postinstall_"&replace(package, '-', '_')):
    postinstallFunc = "postinstall_"&replace(package, '-', '_')
  elif pkg.run3Data.parsed.hasFunction("postinstall"):
    postinstallFunc = "postinstall"

  debug "runPostInstall: "&package&": postinstallFunc: "&postinstallFunc

  if postinstallFunc != "":
    if executeRun3Stage(ctx, pkg.run3Data.parsed, postinstallFunc) != 0:
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

    # Generated archive-root metadata is registered in the package DB but is
    # never present in installed roots; skip it without weakening payload
    # validation.
    if isArchiveRootMetadata(listFilesSplitted):
      continue

    if not (fileExists(root&"/"&listFilesSplitted) or dirExists(
            root&"/"&listFilesSplitted) or symlinkExists(
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

    if fileExists(root&"/"&listFilesSplitted) or symlinkExists(
        root&"/"&listFilesSplitted):
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



proc dependencyFirstPackages*(sortOrder: seq[string]): seq[string] =
  ## Keep resolver order while removing blank and repeated graph nodes.
  return deduplicate(sortOrder.filterIt(not isEmptyOrWhitespace(it)))

proc installFromRoot*(packages: seq[string], root, destdir: string,
        removeDestdirOnError = false, ignorePostInstall = false): seq[string] =
  ## Copy the union of all requested dependency closures exactly once.
  ## Resolving each direct dependency separately repeats almost all metadata
  ## checks and file copies for packages with overlapping closures.
  let roots = deduplicate(packages.filterIt(not isEmptyOrWhitespace(it)))
  if roots.len == 0:
    return

  let (_, _, sortResult) = dephandlerWithGraph(roots, root = root,
          chkInstalledDirInstead = true, forceInstallAll = true)
  let depsUsed = dependencyFirstPackages(sortResult.order)
  for dep in depsUsed:
    if isEmptyOrWhitespace(dep):
      continue

    try:
      installFromRootInternal(dep, root, destdir, removeDestdirOnError,
              ignorePostInstall)
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

proc installFromRoot*(package, root, destdir: string,
        removeDestdirOnError = false, ignorePostInstall = false): seq[string] =
  ## Compatibility wrapper for one requested package.
  return installFromRoot(@[package], root, destdir, removeDestdirOnError,
          ignorePostInstall)

proc createEnvCtrlC() {.noconv.} =
  info "removing unfinished environment"
  removeDir(kpkgEnvPath)
  quit()


proc checkEnvPackageUpdates*(name, root: string, envRoot = kpkgEnvPath): bool =
  ## Compare the reusable environment with the installed source root.
  ## Repository HEAD can be newer than the root and split packages can have
  ## identities that do not match their parent recipe.
  if not packageExistsExact(name, root):
    return true
  if not packageExistsExact(name, envRoot):
    return true
  let envPkg = getPackageExact(name, envRoot)
  let sourcePkg = getPackageExact(name, root)
  return envPkg.name != sourcePkg.name or
      envPkg.version != sourcePkg.version or
      envPkg.release != sourcePkg.release or
      envPkg.epoch != sourcePkg.epoch


proc createEnv(root: string, ignorePostInstall = false,
               deferPostInstall = false) =
  # TODO: cross-compilation support
  info "initializing sandbox, this might take a while..."
  setControlCHook(createEnvCtrlC)
  invalidateEnvSetup(kpkgEnvPath)
  initDirectories(kpkgEnvPath, hostCPU, true)

  # The env has to carry a release file of its own: kpkgTarget() and friends read
  # it back out of kpkgEnvPath while a build is running. On a real Kreato host we
  # copy the host file, and on a foreign host we write the synthesized one so the
  # env is self-describing either way.
  let dict = resolveRelease(root)
  createDir(kpkgEnvPath & "/etc")
  dict.writeConfig(kpkgEnvPath / kreatoReleaseName)

  let libc = dict.getSectionValue("Core", "libc")
  let compiler = dict.getSectionValue("Core", "compiler")
  var envRoots = @[libc]
  envRoots.add(if compiler == "clang": "llvm" else: compiler)

  case dict.getSectionValue("Core", "coreutils"):
    of "gnu":
      envRoots.add(["gnu-coreutils", "pigz", "xz-utils", "bash", "gsed",
              "bzip2", "patch", "diffutils", "findutils", "util-linux",
              "bc", "cpio", "which"])
    of "busybox":
      envRoots.add("busybox")

  envRoots.add(dict.getSectionValue("Core", "tlsLibrary"))
  let init = dict.getSectionValue("Core", "init")
  envRoots.add(init)
  if init == "systemd":
    envRoots.add("dbus")
  envRoots.add("kreato-fs-essentials git kpkg ca-certificates python python-pip gmake".split(" "))

  let depsTotal = installFromRoot(envRoots, root, kpkgEnvPath,
          ignorePostInstall = true)

  try:
    setDefaultCC(kpkgEnvPath, compiler)
  except:
    removeDir(kpkgEnvPath)
    when defined(release):
      error("setting default compiler in the environment failed")
      quit(1)
    else:
      raise getCurrentException()


  #let extras = dict.getSectionValue("Extras", "extraPackages").split(" ")

  #if not isEmptyOrWhitespace(extras.join("")):
  #    for i in extras:
  #        installFromRoot(i, root, kpkgEnvPath)

  proc updateTrust() =
    let result = execCmdKpkg("bwrap --bind "&kpkgEnvPath&" / --bind /etc/resolv.conf /etc/resolv.conf /usr/bin/env update-ca-trust",
            silentMode = false)
    if result.exitCode != 0:
      debug "bwrap update-ca-trust failed with exit code: " & $result.exitCode
      debug "bwrap output: " & result.output
      removeDir(kpkgEnvPath)
      error("creating sandbox environment failed")
      quit(1)

  proc postInstall() =
    runPostInstall(libc, kpkgEnvPath)
    for dep in deduplicate(depsTotal):
      if isEmptyOrWhitespace(dep) or dep == libc:
        continue
      runPostInstall(dep, kpkgEnvPath)

  # The env loader only searches its compiled-in defaults plus /etc/ld.so.conf.
  # Ship the host config (or the standard directories when the host has none)
  # and rebuild the cache inside the env so env binaries resolve host-installed
  # libraries before any postinstall hook runs.
  if fileExists(root&"/etc/ld.so.conf"):
    copyFile(root&"/etc/ld.so.conf", kpkgEnvPath&"/etc/ld.so.conf")
  else:
    writeFile(kpkgEnvPath&"/etc/ld.so.conf",
        "/lib\n/usr/lib\n/lib64\n/usr/lib64\n")
  let ldconfigResult = execCmdKpkg("bwrap --bind "&kpkgEnvPath &
      " / --bind /etc/resolv.conf /etc/resolv.conf ldconfig",
      silentMode = false)
  if ldconfigResult.exitCode != 0:
    debug "bwrap ldconfig failed with exit code: " & $ldconfigResult.exitCode
    debug "bwrap output: " & ldconfigResult.output
    removeDir(kpkgEnvPath)
    error("rebuilding sandbox loader cache failed")
    quit(1)

  if deferPostInstall:
    warn "sandbox postinstall and CA setup deferred for repair; rebuild without deferPostInstall to initialize normally"
  finishEnvSetup(kpkgEnvPath, updateTrust, postInstall,
      deferPostInstall = deferPostInstall,
      ignorePostInstall = ignorePostInstall)


proc umountOverlay*(error = "none", silentMode = false, merged = kpkgMergedPath,
        upperDir = kpkgOverlayPath&"/upperDir",
        workDir = kpkgOverlayPath&"/workDir"): int =
  ## Unmount and remove the overlay directories.
  ##
  ## Overlay setup can be partial, so inspect the actual mount table instead
  ## of requiring every expected directory to exist.  Only issue umount for
  ## real mount points; ordinary directories are simply removed below.
  proc isMounted(path: string): bool =
    if not fileExists("/proc/self/mountinfo"):
      return false
    # All overlay paths passed here are absolute.  Avoid absolutePath(), which
    # queries the current working directory even for an absolute input: a
    # failed transaction may already have removed that directory.
    let mountPath = path
    for line in lines("/proc/self/mountinfo"):
      let fields = line.splitWhitespace()
      if fields.len > 4 and fields[4] == mountPath:
        return true
    return false

  if isMounted(merged) or isMounted(kpkgOverlayPath):
    closeDb()

  if isMounted(merged):
    result = execCmdKpkg("umount "&quoteShell(merged), error,
            silentMode).exitCode
    if result != 0:
      return

  # The tmpfs backing the overlay must be unmounted after the merged overlay.
  if isMounted(kpkgOverlayPath):
    result = execCmdKpkg("umount "&quoteShell(kpkgOverlayPath), error,
            silentMode).exitCode
    if result != 0:
      return

  for path in [merged, upperDir, workDir]:
    if dirExists(path):
      removeDir(path)

  if dirExists(kpkgOverlayPath):
    removeDir(kpkgOverlayPath)


proc createOrUpgradeEnv*(root: string, ignorePostInstall = false,
                         deferPostInstall = false) =
  ## Creates and upgrades environment (if needed).
  ## Deferred or incomplete environments are never reused by normal builds.

  if canReuseEnv(kpkgEnvPath, deferPostInstall, ignorePostInstall):
    try:
      var needsReinit = false
      let envPkgList = getListPackages(kpkgEnvPath)

      for pkg in envPkgList:
        if checkEnvPackageUpdates(pkg, root):
          debug "upgradeEnv: base package '"&pkg&"' is mismatching with the system, reinitializing environment"
          needsReinit = true

      if not needsReinit:
        # Repair builds may modify the lower env without running hooks. Do not
        # let a later normal build reuse that env as fully initialized.
        if deferPostInstall:
          markEnvDeferred(kpkgEnvPath)
        return

    except:
      debug "upgradeEnv: something failed, reinitializing anyway"

  let umountExit = umountOverlay()
  if umountExit != 0:
    fatal("createOrUpgradeEnv: umountOverlay failed, exit code " & $umountExit)
  removeDir(kpkgEnvPath)
  createEnv(root, ignorePostInstall, deferPostInstall)


proc prepareOverlayDirs*(upperDir = kpkgOverlayPath&"/upperDir",
        workDir = kpkgOverlayPath&"/workDir", merged = kpkgMergedPath,
        error = "none", silentMode = false): int =
  ## Prepare the tmpfs and directories used by an overlay build.
  ## Any mount acquired here is either returned fully prepared to the caller
  ## or released before this procedure returns.
  result = umountOverlay(error, silentMode, merged, upperDir, workDir)
  if result != 0:
    return

  createDir(kpkgOverlayPath)
  result = execCmdKpkg("mount -t tmpfs tmpfs "&quoteShell(kpkgOverlayPath),
          silentMode = silentMode).exitCode
  if result != 0:
    removeDir(kpkgOverlayPath)
    return

  var prepared = false
  try:
    createDir(upperDir)
    createDir(merged)
    createDir(workDir)
    initDirectories(upperDir, hostCPU, true)
    prepared = true
    result = 0
  finally:
    if not prepared:
      discard umountOverlay(silentMode = true, merged = merged,
              upperDir = upperDir, workDir = workDir)


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
  result = prepareOverlayDirs(upperDir, workDir, merged, error, silentMode)
  if result != 0:
    return

  result = mountOverlayFilesystem(upperDir, workDir, lowerDir, merged,
          error, silentMode)
  if result != 0:
    discard umountOverlay(silentMode = true, merged = merged,
            upperDir = upperDir, workDir = workDir)
