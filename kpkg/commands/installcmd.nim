import os
import osproc
import std/httpclient
import std/typedthreads
import std/locks
import times
import posix
import strutils
import sequtils
import parsecfg
import tables
import ../modules/sqlite
import ../modules/config
import ../../common/logging
import ../modules/lockfile
import ../modules/checksums
import ../modules/runparser
import ../modules/processes
import ../modules/downloader
import ../modules/config as kpkgConfig
import ../modules/dephandler
import ../modules/libarchive
import ../modules/commonTasks
import ../modules/commonPaths
import ../modules/removeInternal
import ../modules/transaction
import ../modules/run3/run3
import ../modules/staleprocs
import ../modules/builder/commitctx
import ../modules/telemetry/main as telemetry

setControlCHook(ctrlc)

type
  FileToInstall = object
    srcPath: string  # Path in the extracted temp directory
    destPath: string # Final destination path in root
    relPath: string  # Relative path for database
    checksum: string # Blake2 checksum
    isDir: bool      # Whether this is a directory
    isSymlink: bool  # Whether this is a symlink

var runfileParseLock: Lock
initLock(runfileParseLock)

proc validateExtractedFiles(kpkgInstallTemp: string, extractTarball: seq[string],
                            dict: Config, pkg: runFile,
                            raiseErrors = false): seq[FileToInstall] =
  ## Validate all extracted files and return a list of files to install.
  ## This is the "check" phase - no side effects on the target system.
  result = @[]

  for file in extractTarball:
    if "pkgsums.ini" == lastPathPart(file) or "pkgInfo.ini" == lastPathPart(file):
      continue

    # libarchive returns archive-relative names; only normalize absolute
    # names. This avoids resolving a relative entry against the process cwd.
    var relPath = if file.isAbsolute: relativePath(file, kpkgInstallTemp)
                  else: file
    # Archives created with "tar -C <parent> ." store entries with a leading
    # "./" while pkgsums.ini keys never carry it. Normalize so the manifest
    # lookup and destination paths match regardless of how the archive was
    # packed.
    while relPath.startsWith("./"):
      relPath = relPath[2 ..^ 1]
    let srcPath = kpkgInstallTemp & "/" & relPath
    let value = dict.getSectionValue("", relPath)

    let isSymlink = symlinkExists(srcPath)
    let isRegularFile = fileExists(srcPath) and not isSymlink
    let isDir = dirExists(srcPath) and not isSymlink

    # Validate checksums for regular files
    if isRegularFile:
      if isEmptyOrWhitespace(value):
        debug file
        if raiseErrors:
          raise newException(IOError, "package sums invalid - file exists but no checksum in manifest")
        fatal("package sums invalid - file exists but no checksum in manifest")

      let actualSum = getSum(srcPath, "b2")
      if actualSum != value:
        if raiseErrors:
          raise newException(IOError, "sum for file '" & file & "' invalid")
        fatal("sum for file '" & file & "' invalid")

      result.add(FileToInstall(
        srcPath: srcPath,
        destPath: "", # Will be set later with root
        relPath: relPath,
        checksum: value,
        isDir: false,
        isSymlink: false
      ))
    elif isSymlink:
      result.add(FileToInstall(
        srcPath: srcPath,
        destPath: "",
        relPath: relPath,
        checksum: "",
        isDir: false,
        isSymlink: true
      ))
    elif isDir:
      result.add(FileToInstall(
        srcPath: srcPath,
        destPath: "",
        relPath: relPath,
        checksum: "",
        isDir: true,
        isSymlink: false
      ))

proc backupExistingFiles(tx: Transaction, filesToInstall: var seq[FileToInstall],
                         root: string, pkg: runFile) =
  ## Backup existing files that will be replaced.
  ## This allows rollback if installation fails.
  for i in 0..<filesToInstall.len:
    let destPath = root & "/" & filesToInstall[i].relPath
    filesToInstall[i].destPath = destPath

    # Skip backup files
    if filesToInstall[i].relPath in pkg.backup:
      continue

    # Backup existing files/symlinks (not directories)
    if fileExists(destPath) or symlinkExists(destPath):
      let backupPath = tx.backupFile(destPath)
      if backupPath != "":
        tx.recordFileReplaced(destPath, backupPath)

proc installFilesAtomic(tx: Transaction, filesToInstall: seq[FileToInstall],
                        kpkgInstallTemp: string, root: string, backup: seq[string]) =
  ## Install files with transaction recording for rollback support.

  # First pass: create directories
  for f in filesToInstall:
    if f.isDir:
      if not (dirExists(f.destPath) or symlinkExists(f.destPath)):
        createDirWithPermissionsAndOwnership(f.srcPath, f.destPath)
        tx.recordDirCreated(f.destPath)
        debug "Installed directory: " & f.relPath

  # Second pass: install files and symlinks
  for f in filesToInstall:
    if f.isDir:
      continue

    # Skip backup files if they already exist (preserve user configs)
    if f.relPath in backup and (fileExists(f.destPath) or symlinkExists(
        f.destPath) or dirExists(f.destPath)):
      debug "Skipping backup file (already exists): " & f.relPath
      continue

    # Ensure parent directory exists
    let parentDir = f.destPath.parentDir()
    if not dirExists(parentDir):
      let srcParentDir = f.srcPath.parentDir()
      createDirWithPermissionsAndOwnership(srcParentDir, parentDir)
      tx.recordDirCreated(parentDir)

    # Install through a same-directory temporary path and atomic rename.
    # This avoids exposing a partially copied file to other processes.
    if f.isSymlink:
      copyFileAtomicWithPermissionsAndOwnership(f.srcPath, f.destPath)
      tx.recordSymlinkCreated(f.destPath)
      debug "Installed symlink: " & f.relPath
    else:
      copyFileAtomicWithPermissionsAndOwnership(f.srcPath, f.destPath)
      tx.recordFileCreated(f.destPath)
      debug "Installed file: " & f.relPath

proc installProgress(index, percent, progressStart: int) =
  if index >= 0:
    let scaled = progressStart + percent * (100 - progressStart) div 100
    progressUpdate(index, scaled, detail = "installing")

proc installPkgImpl(repo: string, package: string, root: string, runf = runFile(
        isParsed: false), manualInstallList: seq[string], isUpgrade = false,
                kTarget = kpkgTarget(root), ignorePostInstall = false,
                disablePkgInfo = false, ignorePreInstall = false,
                basePackage = false, version = "", tarballPath = "",
                keepTransaction = false, progressIndex = -1,
                progressStart = 0) =
  ## Installs a package atomically with transaction support.
  ## If installation fails at any point, changes are rolled back.

  var pkg: runFile

  try:
    if runf.isParsed:
      pkg = runf
    else:
      debug "parseRunfile ran, installPkg"
      pkg = runparser.parseRunfile(repo&"/"&package)
  except CatchableError:
    if keepTransaction:
      raise newException(IOError,
          "Unknown error while trying to parse package on repository, possibly broken repo?")
    fatal("Unknown error while trying to parse package on repository, possibly broken repo?")

  debug "installPkg ran, repo: '"&repo&"', package: '"&package&"', root: '"&root&"', manualInstallList: '"&manualInstallList.join(
      " ")&"', kTarget: '"&kTarget&"'"

  # If the target root doesn't have /etc/kreato-release (e.g. sandbox upperDir),
  # fall back to the env path so kpkgTarget() can still read it.
  let kreatoReleasePath = if fileExists(root & "/etc/kreato-release"):
    root & "/etc/kreato-release"
  else:
    kpkgEnvPath & "/etc/kreato-release"

  let isUpgradeActual = (packageExists(package, root) and getPackage(package,
          root).version != pkg.versionString) or isUpgrade

  # Prepare Context for run3 scripts
  let ctx = initRun3ContextFromParsed(pkg.run3Data.parsed, destDir = root,
          srcDir = repo&"/"&package, buildRoot = root)
  ctx.builtinEnv("ROOT", root)
  ctx.builtinEnv("DESTDIR", root)
  ctx.passthrough = true

  # Run preupgrade hook (before any changes)
  if isUpgradeActual:
    let preupgradeFunc = resolveHookFunction(pkg.run3Data.parsed, "preupgrade", package)
    if preupgradeFunc != "":
      if executeRun3Stage(ctx, pkg.run3Data.parsed, preupgradeFunc) != 0:
        fatal("preupgrade failed")

  # Run preinstall hook (before any changes)
  if not packageExists(package, root):
    let preinstallFunc = resolveHookFunction(pkg.run3Data.parsed, "preinstall", package)
    if preinstallFunc != "":
      if executeRun3Stage(ctx, pkg.run3Data.parsed, preinstallFunc) != 0:
        if ignorePreInstall:
          warn "preinstall failed"
        else:
          if keepTransaction:
            raise newException(IOError, "preinstall failed")
          fatal("preinstall failed")

  let isGroup = pkg.isGroup

  # Check for conflicts
  for i in pkg.conflicts:
    if packageExists(i, root):
      if keepTransaction:
        raise newException(IOError, i&" conflicts with "&package)
      fatal(i&" conflicts with "&package)

  # Setup temp directories
  removeDir("/tmp/kpkg/reinstall/"&package&"-old")
  createDir("/tmp")
  createDir("/tmp/kpkg")

  var tarball: string
  var pkgVersion = pkg.versionString

  if not isEmptyOrWhitespace(version):
    pkgVersion = version

  if not isGroup:
    if tarballPath.len > 0:
      tarball = tarballPath
    else:
      tarball = kpkgArchivesDir&"/system/"&kTarget&"/"&package&"-"&pkgVersion&".kpkg"


  # Create transaction for atomic installation
  var tx = newTransaction(package, root)

  try:
    # Handle package replacements with transaction support
    for i in pkg.replaces:
      if packageExists(i, root):
        let replacedInfo = isReplaced(i, root)
        if replacedInfo.replaced:
          debug "Package '"&i&"' is already replaced by '"&replacedInfo.package.name&"', skipping removal"
          continue

        # Backup files from replaced package before removal
        let replacedFiles = getListFiles(i, root)
        for f in replacedFiles:
          let fullPath = root & "/" & f
          if fileExists(fullPath) or symlinkExists(fullPath):
            let backupPath = tx.backupFile(fullPath)
            if backupPath != "":
              tx.recordFileDeleted(fullPath, backupPath)

        if kTarget != kpkgTarget(root, releasePath = kreatoReleasePath):
          removeInternal(i, root, initCheck = false)
        else:
          removeInternal(i, root, kreatoPath = kreatoReleasePath)

    # Handle reinstallation - backup old package files
    let wasInstalled = packageExists(package, root) and (not isGroup)
    if wasInstalled:
      info "package already installed, reinstalling"

      # Backup all files from the old package
      let oldFiles = getListFiles(package, root)
      for f in oldFiles:
        let fullPath = root & "/" & f
        if fileExists(fullPath) or symlinkExists(fullPath):
          let backupPath = tx.backupFile(fullPath)
          if backupPath != "":
            tx.recordFileDeleted(fullPath, backupPath)

      # Remove old package from database (but files are backed up)
      if kTarget != kpkgTarget(root, releasePath = kreatoReleasePath):
        removeInternal(package, root, ignoreReplaces = true,
                noRunfile = true, initCheck = false)
      else:
        removeInternal(package, root, ignoreReplaces = true,
                noRunfile = false, depCheck = false,
                kreatoPath = kreatoReleasePath)

    discard existsOrCreateDir(root&"/var")
    discard existsOrCreateDir(root&"/var/cache")
    discard existsOrCreateDir(root&kpkgCacheDir)

    let kpkgInstallTemp = kpkgTempDir1&"/install-"&package
    if not isGroup:
      var extractTarball: seq[string]
      if dirExists(kpkgInstallTemp):
        removeDir(kpkgInstallTemp)

      createDir(kpkgInstallTemp)

      # Phase 1: Extract using independent libarchive reader/writer handles.
      # extract() no longer changes process cwd, so independent package
      # archives can safely extract concurrently.
      try:
        extractTarball = extract(tarball, kpkgInstallTemp)
      except Exception:
        when defined(release):
          tx.rollback()
          if keepTransaction:
            raise newException(IOError, "extracting the tarball failed for "&package)
          fatal("extracting the tarball failed for "&package)
        else:
          tx.rollback()
          removeLockfile()
          raise getCurrentException()

      installProgress(progressIndex, 22, progressStart)
      var dict = loadConfig(kpkgInstallTemp&"/pkgsums.ini")

      # Phase 2: Validate all files (no side effects)
      var filesToInstall = validateExtractedFiles(kpkgInstallTemp,
          extractTarball, dict, pkg, raiseErrors = keepTransaction)

      # Update destination paths
      for i in 0..<filesToInstall.len:
        filesToInstall[i].destPath = root & "/" & filesToInstall[i].relPath

      installProgress(progressIndex, 38, progressStart)

      # Phase 3: Check pkgInfo dependencies
      if fileExists(kpkgInstallTemp&"/pkgInfo.ini") and (not disablePkgInfo):
        var dict2 = loadConfig(kpkgInstallTemp&"/pkgInfo.ini")

        for dep in dict2.getSectionValue("", "depends").split(" "):
          if isEmptyOrWhitespace(dep):
            continue

          let depClean = dep.strip()
          if isEmptyOrWhitespace(depClean):
            continue

          let hashPos = depClean.find('#')

          if hashPos < 0 or hashPos == depClean.high:
            warn "pkgInfo lists dependency '"&depClean&"', but it is missing a version; skipping check"
            continue

          let depName = depClean[0 ..< hashPos].strip()
          let depVersion = depClean[(hashPos + 1) .. depClean.high].strip()

          if isEmptyOrWhitespace(depName) or isEmptyOrWhitespace(depVersion):
            warn "pkgInfo lists dependency '"&depClean&"', but it is missing a name or version; skipping check"
            continue

          if not packageExists(depName, root):
            warn "pkgInfo lists dependency '"&depName&"', but it is not installed at '"&root&"'; skipping version check"
            continue

          var db: Package
          try:
            db = getPackage(depName, root)
          except:
            if isEnabled(lvlDebug):
              debug "getPackage failed for '"&depName&"' at root '"&root&"'"
              debug "pkgInfo.ini content:"
              try:
                let pkgInfoContent = readFile(kpkgInstallTemp&"/pkgInfo.ini")
                for line in pkgInfoContent.splitLines():
                  debug "  "&line
              except:
                debug "  (could not read pkgInfo.ini file)"
            tx.rollback()
            raise

          if db.version != depVersion:
            warn "this package is built with '"&depName&"#"&depVersion&"', while the system has '"&depName&"#"&db.version&"'"
            warn "installing anyway, but issues may occur"
            warn "this may be an error in the future"

      # Phase 4: Backup existing files that will be replaced
      backupExistingFiles(tx, filesToInstall, root, pkg)

      # Phase 5: Install files with transaction recording
      installFilesAtomic(tx, filesToInstall, kpkgInstallTemp, root, pkg.backup)

      installProgress(progressIndex, 72, progressStart)

      # Phase 6: Update database (after all files are installed)
      var mI = false
      if package in manualInstallList:
        debug "Setting as manually installed"
        mI = true

      # Use database transaction for atomicity
      beginTransaction(root)
      try:
        var pkgType = newPackage(package, pkgVersion, pkg.release, pkg.epoch,
                pkg.deps.join("!!k!!"), pkg.bdeps.join("!!k!!"),
                pkg.backup.join("!!k!!"), pkg.replaces.join("!!k!!"),
                pkg.license.join("!!k!!"), pkg.desc,
                mI, pkg.isGroup, basePackage, root)

        # Add file entries to database
        pkgSumsToSQL(kpkgInstallTemp&"/pkgsums.ini", pkgType, root)

        commitTransaction(root)
      except:
        rollbackTransaction(root)
        tx.rollback()
        raise

      installProgress(progressIndex, 86, progressStart)

    else:
      # Register group packages in the database
      var mI = false
      if package in manualInstallList:
        debug "Setting as manually installed"
        mI = true

      beginTransaction(root)
      try:
        discard newPackage(package, pkgVersion, pkg.release, pkg.epoch,
                pkg.deps.join("!!k!!"), pkg.bdeps.join("!!k!!"),
                pkg.backup.join("!!k!!"), pkg.replaces.join("!!k!!"),
                pkg.license.join("!!k!!"), pkg.desc,
                mI, pkg.isGroup, basePackage, root)
        commitTransaction(root)
      except:
        rollbackTransaction(root)
        tx.rollback()
        raise

      installProgress(progressIndex, 86, progressStart)

    installProgress(progressIndex, 91, progressStart)

    # Run ldconfig afterwards for any new libraries.
    ensureValidCwd()
    let ldconfigCmd = if root == "/": "ldconfig" else: "ldconfig -r " & root
    discard execProcess(ldconfigCmd)

    # Phase 7: Run postinstall (BEFORE cleanup so rollback is possible)
    let postinstallFunc = resolveHookFunction(pkg.run3Data.parsed,
        "postinstall", package)
    if postinstallFunc != "":
      if executeRun3Stage(ctx, pkg.run3Data.parsed, postinstallFunc) != 0:
        if ignorePostInstall:
          warn "postinstall failed"
        else:
          tx.rollback()
          rollbackTransaction(root)
          if keepTransaction:
            raise newException(IOError, "postinstall failed")
          fatal("postinstall failed")

    # Phase 8: Run postupgrade
    if isUpgradeActual:
      let postupgradeFunc = resolveHookFunction(pkg.run3Data.parsed,
          "postupgrade", package)
      if postupgradeFunc != "":
        if executeRun3Stage(ctx, pkg.run3Data.parsed, postupgradeFunc) != 0:
          tx.rollback()
          rollbackTransaction(root)
          if keepTransaction:
            raise newException(IOError, "postupgrade failed")
          fatal("postupgrade failed")

    # Phase 9: Commit transaction (removes backups, deletes journal). In a
    # batch install, leave the journal and backups active until every package
    # succeeds; the batch coordinator then finalizes all transactions.
    if keepTransaction:
      debug "Transaction staged: " & tx.id
    else:
      tx.commit()

    # Phase 10: Cleanup temp directories (AFTER successful commit)
    when defined(release):
      # Remove only this installation's extraction directory.  kpkgTempDir1
      # also contains the active sandbox mounts and must never be deleted by
      # the package installer.
      if dirExists(kpkgInstallTemp):
        removeDir(kpkgInstallTemp)

    for i in pkg.optdeps:
      info(i)

  except CatchableError:
    # Rollback on any error
    error "Installation failed, rolling back..."
    tx.rollback()
    raise

proc installPkg*(repo: string, package: string, root: string, runf = runFile(
        isParsed: false), manualInstallList: seq[string], isUpgrade = false,
                kTarget = kpkgTarget(root), ignorePostInstall = false,
                disablePkgInfo = false, ignorePreInstall = false,
                basePackage = false, version = "", tarballPath = "",
                keepTransaction = false, progressIndex = -1,
                progressStart = 0) =
  telemetry.withSpan("kpkg.install", {
    "package.name": package,
    "package.version": version
  }.toTable):
    installPkgImpl(repo, package, root, runf, manualInstallList, isUpgrade,
        kTarget, ignorePostInstall, disablePkgInfo, ignorePreInstall,
        basePackage, version, tarballPath, keepTransaction, progressIndex,
        progressStart)

proc canDownloadBinary*(package: string, version: string, binrepos: seq[string],
        kTarget: string): bool =
  ## Check if a binary is downloadable from any mirror (without actually
  ## downloading). Uses a native HTTP HEAD request with a short timeout
  ## instead of spawning curl.

  let tarball = package & "-" & version & ".kpkg"

  for binrepo in binrepos:
    let url = "https://" & binrepo & "/archives/system/" & kTarget & "/" & tarball
    try:
      var client = newHttpClient(timeout = 10, userAgent = "kpkg")
      defer: client.close()
      let resp = client.request(url, HttpHead)
      if resp.code.is2xx:
        debug "canDownloadBinary: Binary '" & tarball & "' found at " & binrepo
        return true
    except CatchableError:
      debug "canDownloadBinary: HEAD request to " & binrepo & " failed: " &
          getCurrentExceptionMsg()
      continue

  debug "canDownloadBinary: Binary '" & tarball & "' not found on any mirror"
  return false

proc down_bin*(package: string, binrepos: seq[string], root: string,
        offline: bool, forceDownload = false, ignoreDownloadErrors = false,
                kTarget = kpkgTarget(root), version = "", customPath = "",
                ignoreErrors = false, commit = "") =
  ## Downloads binaries.
  ##
  ## For commit-based installs, the version should be the version at that commit.
  ## If commit is specified and binary not found, returns without error (caller handles it).

  discard existsOrCreateDir("/var/")
  discard existsOrCreateDir("/var/cache")
  discard existsOrCreateDir("/var/cache/kpkg")
  discard existsOrCreateDir(kpkgArchivesDir)
  discard existsOrCreateDir(kpkgArchivesDir&"/system")
  discard existsOrCreateDir(kpkgArchivesDir&"/system/"&kTarget)

  var downSuccess: bool

  var binreposFinal = binrepos

  var override: Config

  if fileExists("/etc/kpkg/override/"&package&".conf"):
    override = loadConfig("/etc/kpkg/override/"&package&".conf")
  else:
    override = newConfig() # So we don't get storage access errors

  let binreposOverride = override.getSectionValue("Mirror", "binaryMirrors")

  if not isEmptyOrWhitespace(binreposOverride):
    binreposFinal = binreposOverride.split(" ")

  var pkgVersion = version

  if isEmptyOrWhitespace(pkgVersion):
    var repo = findPkgRepo(package)
    var pkg: runFile

    try:
      debug "parseRunfile ran, down_bin"
      pkg = runparser.parseRunfile(repo&"/"&package)
    except CatchableError:
      const msg = "Unknown error while trying to parse package on repository, possibly broken repo?"
      if ignoreErrors:
        debug msg
        return
      else:
        fatal(msg)

    if pkg.isGroup:
      return

    pkgVersion = pkg.versionString

  let tarball = package&"-"&pkgVersion&".kpkg"
  var path = kpkgArchivesDir&"/system/"&kTarget&"/"&tarball
  if not isEmptyOrWhitespace(customPath):
    path = customPath

  if fileExists(path) and (not forceDownload):
    debug "Tarball already exists for '"&package&"', not gonna download again"
    downSuccess = true
  elif not offline:
    for binrepo in binreposFinal:
      try:
        download("https://"&binrepo&"/archives/system/"&kTarget&"/"&tarball, path)
        downSuccess = true
        break
      except:
        debug "down_bin: Failed to download from " & binrepo
        continue

    if not downSuccess and commit != "":
      debug "down_bin: Binary for commit '" & commit & "' not found, returning (caller will handle)"
      return
  else:
    const msg = "attempted to download tarball from binary repository in offline mode"
    debug path
    if ignoreErrors:
      debug msg
      return
    else:
      if commit != "":
        debug "down_bin: Offline mode, commit package not cached"
        return
      fatal(msg)

  if not downSuccess and not ignoreDownloadErrors and commit == "":
    fatal("couldn't download the binary")

proc getMirrorList(package: string, binrepos: seq[string]): seq[string] =
  ## Returns the mirror list for a package, honoring per-package overrides.
  var binreposFinal = binrepos
  if fileExists("/etc/kpkg/override/"&package&".conf"):
    let override = loadConfig("/etc/kpkg/override/"&package&".conf")
    let binreposOverride = override.getSectionValue("Mirror", "binaryMirrors")
    if not isEmptyOrWhitespace(binreposOverride):
      binreposFinal = binreposOverride.split(" ")
  return binreposFinal

proc downloadBatch(packages: seq[string], binrepos: seq[string],
                   versions: Table[string, string], kTarget: string,
                   offline: bool, forceDownloadPackages: seq[string],
                   forceDownload: bool, ignoreDownloadErrors: bool,
                   combinedProgress = false,
                   progressRows = initTable[string, int](),
                   skipPackages: seq[string] = @[],
                   renderUpdates = true,
                   onTick: proc() {.closure.} = nil): bool =
  ## Downloads all package tarballs in parallel using worker threads.
  ## Packages with a cached tarball are skipped. `versions` maps package
  ## name -> version (may be empty for repo lookup); `commit` maps
  ## package name -> commit hash (for logging only).

  result = true
  let threads = kpkgConfig.getDownloadThreads()

  var jobs: seq[DownloadJob] = @[]
  var skipped = 0
  var queuedPaths: seq[string] = @[]
  var jobProgressRows: seq[int] = @[]

  for pkg in packages:
    if pkg in skipPackages:
      if combinedProgress and progressRows.hasKey(pkg):
        progressUpdate(progressRows[pkg], 45, detail = "ready")
      continue
    var version = versions.getOrDefault(pkg, "")
    if isEmptyOrWhitespace(version):
      # Resolve version from the repository runfile
      try:
        let repo = findPkgRepo(pkg)
        let rf = runparser.parseRunfile(repo & "/" & pkg)
        if rf.isGroup:
          debug "downloadBatch: '" & pkg & "' is a group, skipping"
          continue
        version = rf.versionString
      except CatchableError:
        debug "downloadBatch: could not resolve version for '" & pkg & "', leaving to serial path"
        continue
    if isEmptyOrWhitespace(version):
      continue

    let tarball = pkg & "-" & version & ".kpkg"
    let path = kpkgArchivesDir & "/system/" & kTarget & "/" & tarball

    let fdownload = forceDownload or (pkg in forceDownloadPackages)
    if fileExists(path) and not fdownload:
      debug "downloadBatch: tarball already cached for '" & pkg & "'"
      if combinedProgress and progressRows.hasKey(pkg):
        progressUpdate(progressRows[pkg], 45, detail = "downloaded")
      inc skipped
      continue

    # A package may appear multiple times in the resolved set (e.g. as a
    # dependency and as an explicit reinstall target); only download once.
    if path in queuedPaths:
      debug "downloadBatch: duplicate tarball for '" & pkg & "', skipping"
      inc skipped
      continue
    queuedPaths.add(path)

    var urls: seq[string] = @[]
    for binrepo in getMirrorList(pkg, binrepos):
      urls.add("https://" & binrepo & "/archives/system/" & kTarget & "/" & tarball)

    if urls.len == 0:
      continue

    discard existsOrCreateDir(kpkgArchivesDir)
    discard existsOrCreateDir(kpkgArchivesDir & "/system")
    discard existsOrCreateDir(kpkgArchivesDir & "/system/" & kTarget)

    jobs.add(DownloadJob(label: pkg, urls: urls, destPath: path))
    jobProgressRows.add(if progressRows.hasKey(pkg): progressRows[pkg]
        else: jobs.high)

  if jobs.len == 0:
    debug "downloadBatch: nothing to download"
    return

  if not offline:
    if combinedProgress:
      debug "downloading " & $jobs.len & " package(s) using " & $threads & " thread(s)"
    else:
      info "downloading " & $jobs.len & " package(s) using " & $threads & " thread(s)"
    let results = downloadParallel(jobs, threads,
        manageProgress = not combinedProgress,
        progressIndices = jobProgressRows,
        progressStart = 0,
        progressEnd = if combinedProgress: 45 else: 100,
        renderUpdates = renderUpdates, onTick = onTick)

    for r in results:
      if not r.ok and not ignoreDownloadErrors:
        if not combinedProgress:
          error "failed to download '" & r.label & "'"
        result = false
  else:
    const msg = "attempted to download tarball from binary repository in offline mode"
    for j in jobs:
      debug msg & " (" & j.label & ")"
    if not ignoreDownloadErrors:
      result = false


type
  InstallWorkItem = object
    name: string
    repo: string
    root: string
    kTarget: string
    version: string
    basePackage: bool
    manual: bool
    deps: seq[string]
    conflicts: seq[string]
    replaces: seq[string]
    isGroup: bool
    keepTransaction: bool
    progressIndex: int
    progressStart: int
    idx: int

  InstallResult = object
    idx: int
    ok: bool
    errorMsg: string
    deferredLogs: seq[string]

var
  installWorkChan: Channel[InstallWorkItem]
  installResultChan: Channel[InstallResult]

proc installWorkerThread() {.thread.} =
  {.cast(gcsafe).}:
    try:
      while true:
        let item = installWorkChan.recv()
        if item.name == "\x00quit":
          break
        setProgressInfoSuppressed(true)
        try:
          # run3 parsing has process-global mutable state. Parse under a lock,
          # then execute the package outside it.
          var parsedRunf: runFile
          acquire(runfileParseLock)
          try:
            parsedRunf = runparser.parseRunfile(item.repo & "/" & item.name)
          finally:
            release(runfileParseLock)
          progressUpdate(item.progressIndex, item.progressStart,
              detail = "installing")
          installPkg(item.repo, item.name, item.root, runf = parsedRunf,
              manualInstallList = if item.manual: @[item.name] else: @[],
              kTarget = item.kTarget, basePackage = item.basePackage,
              version = item.version, keepTransaction = item.keepTransaction,
              progressIndex = item.progressIndex,
              progressStart = item.progressStart)
          progressUpdate(item.progressIndex, 100, finished = true, ok = true,
              detail = "done")
          installResultChan.send(InstallResult(idx: item.idx, ok: true,
              deferredLogs: takeDeferredProgressLogs()))
        except CatchableError:
          let errorMsg = getCurrentExceptionMsg()
          progressUpdate(item.progressIndex, 100, finished = true, ok = false,
              detail = "failed")
          installResultChan.send(InstallResult(idx: item.idx, ok: false,
              errorMsg: errorMsg,
              deferredLogs: takeDeferredProgressLogs()))
        finally:
          setProgressInfoSuppressed(false)
    finally:
      # Flush this thread's WAL connection before it exits.
      closeDb()

proc installLayerParallel(layer: seq[InstallWorkItem], workerLimit: int,
        manageProgress = true): seq[InstallResult] =
  ## Installs an independent dependency layer concurrently. Each worker has
  ## its own SQLite connection; filesystem changes are journaled per package.
  result = @[]
  if layer.len == 0:
    return

  let workerCount = max(1, min(workerLimit, layer.len))
  var progressLabels: seq[string] = @[]
  for item in layer:
    progressLabels.add(item.name)
  if manageProgress:
    progressBegin(progressLabels, "")
  installWorkChan.open(layer.len + workerCount + 4)
  installResultChan.open(layer.len + 4)

  var workers = newSeq[Thread[void]](workerCount)
  for i in 0 ..< workerCount:
    createThread(workers[i], installWorkerThread)

  for item in layer:
    installWorkChan.send(item)
  for i in 0 ..< workerCount:
    installWorkChan.send(InstallWorkItem(name: "\x00quit"))

  var completed = 0
  var deferredLogs: seq[string] = @[]
  while completed < layer.len:
    while installResultChan.peek() > 0:
      let itemResult = installResultChan.recv()
      result.add(itemResult)
      deferredLogs.add(itemResult.deferredLogs)
      inc completed
    progressRender()
    if completed < layer.len:
      sleep(100)

  for worker in workers.mitems:
    joinThread(worker)
  if manageProgress:
    progressFinish()
    # Print worker warnings/errors only after the cursor is below the completed
    # progress block, preventing stderr from overwriting an active row.
    for line in deferredLogs:
      stderr.writeLine(line)
    if deferredLogs.len > 0:
      stderr.flushFile()
  installWorkChan.close()
  installResultChan.close()


type
  BatchInstallState = object
    root: string
    dbPath: string
    dbBackupPath: string
    journalPath: string
    hadDatabase: bool
    activeTransactionIds: seq[string]

proc beginBatchInstall(root: string): BatchInstallState =
  ## Snapshot metadata and remember pre-existing journals before staging the
  ## package transactions. The database is restored only after all workers
  ## have stopped, so no SQLite connection is copied while it is in use.
  result.root = root
  result.dbPath = root & "/" & kpkgDbPath
  result.hadDatabase = fileExists(result.dbPath)
  for tx in getActiveTransactions():
    result.activeTransactionIds.add(tx.id)
  if result.hadDatabase:
    closeDb()
    result.dbBackupPath = kpkgTempDir2 & "/batch-db-" & $getpid() & "-" &
        $int(epochTime() * 1_000_000)
    createDir(kpkgTempDir2)
    copyFile(result.dbPath, result.dbBackupPath)
  let batchId = $getpid() & "-" & $int(epochTime() * 1_000_000)
  result.journalPath = beginBatchJournal(batchId, root, result.dbPath,
      result.dbBackupPath, result.hadDatabase)

proc isBatchTransaction(state: BatchInstallState, id: string): bool =
  id notin state.activeTransactionIds

proc rollbackBatchInstall(state: BatchInstallState) =
  ## Roll back all package journals created by this batch, then restore the
  ## exact pre-batch SQLite image. Workers are joined before this is called.
  for tx in getActiveTransactions():
    if state.isBatchTransaction(tx.id):
      tx.rollback()

  closeDb()
  if fileExists(state.dbPath):
    removeFile(state.dbPath)
  for suffix in ["-wal", "-shm"]:
    let sidecar = state.dbPath & suffix
    if fileExists(sidecar):
      removeFile(sidecar)
  if state.hadDatabase and fileExists(state.dbBackupPath):
    copyFile(state.dbBackupPath, state.dbPath)
  if state.dbBackupPath != "" and fileExists(state.dbBackupPath):
    removeFile(state.dbBackupPath)
  finishBatchJournal(state.journalPath)

proc finalizeBatchInstall(state: BatchInstallState) =
  ## Make all staged package journals durable only after the complete batch
  ## has succeeded.
  for tx in getActiveTransactions():
    if state.isBatchTransaction(tx.id):
      tx.commit()
  if state.dbBackupPath != "" and fileExists(state.dbBackupPath):
    removeFile(state.dbBackupPath)
  finishBatchJournal(state.journalPath)

proc install_bin(packages: seq[string], binrepos: seq[string], root: string,
        offline: bool, downloadOnly = false, manualInstallList: seq[string],
                kTarget = kpkgTarget(root), forceDownload = false,
                ignoreDownloadErrors = false, forceDownloadPackages = @[""],
                basePackage = false,
                commitContexts: Table[string, InstallCommitContext] = initTable[
                    string, InstallCommitContext]()) =
  ## Downloads and installs binaries.
  ##
  ## For commit-based installs:
  ## - Uses version from commit context for download lookup
  ## - Checks if binary exists before download
  ## - Provides helpful error if binary not found

  withLockfile:
    # Phase 1: resolve versions and validate commit-based installs
    var versions = initTable[string, string]()
    var commits = initTable[string, string]()
    var downloadNames: seq[string] = @[]

    for i in packages:
      let pkgParsed = parsePkgInfo(i)
      var versionToUse = pkgParsed.version
      var commitToUse = ""

      if pkgParsed.commit != "":
        commitToUse = pkgParsed.commit
        if pkgParsed.name in commitContexts and commitContexts[
            pkgParsed.name].commit != "":
          versionToUse = commitContexts[pkgParsed.name].versionAtCommit
          info "Installing '" & pkgParsed.name & "#" & commitToUse &
              "' (version " & versionToUse & ")"

      if pkgParsed.commit != "" and versionToUse != "":
        let tarballPath = kpkgArchivesDir & "/system/" & kTarget & "/" &
            pkgParsed.name & "-" & versionToUse & ".kpkg"

        if not fileExists(tarballPath):
          if offline:
            error("Binary for '" & pkgParsed.name & "#" & commitToUse &
                "' (version " & versionToUse & ") not cached")
            info("Use 'kpkg build " & pkgParsed.name & "#" & commitToUse & "' to build from source at this commit")
            quit(1)

          let canDown = canDownloadBinary(pkgParsed.name, versionToUse,
              binrepos, kTarget)
          if not canDown:
            error("Binary for '" & pkgParsed.name & "#" & commitToUse &
                "' (version " & versionToUse & ") not found on mirrors")
            info("Use 'kpkg build " & pkgParsed.name & "#" & commitToUse & "' to build from source at this commit")
            quit(1)

      if pkgParsed.name notin versions or isEmptyOrWhitespace(versions[pkgParsed.name]):
        versions[pkgParsed.name] = versionToUse
      commits[pkgParsed.name] = commitToUse
      downloadNames.add(pkgParsed.name)

    if downloadOnly:
      if not downloadBatch(downloadNames, binrepos, versions, kTarget, offline,
              forceDownloadPackages, forceDownload, ignoreDownloadErrors):
        raise newException(IOError, "one or more package downloads failed")
    else:
      # Resolve installation metadata before starting either pool. This gives
      # the scheduler a dependency graph and exact archive paths while keeping
      # run3 parsing serialized.
      var installItems: seq[InstallWorkItem] = @[]
      var itemNames: seq[string] = @[]
      var groupNames: seq[string] = @[]

      for i in packages:
        let pkgParsed = parsePkgInfo(i)
        if pkgParsed.name in itemNames:
          continue
        let itemRepo = if pkgParsed.repo != "": pkgParsed.repo
                       else: findPkgRepo(pkgParsed.name)
        var itemRunf: runFile
        acquire(runfileParseLock)
        try:
          itemRunf = runparser.parseRunfile(itemRepo & "/" & pkgParsed.name)
        finally:
          release(runfileParseLock)

        var versionToUse = pkgParsed.version
        if pkgParsed.commit != "" and pkgParsed.name in commitContexts and
            commitContexts[pkgParsed.name].commit != "":
          versionToUse = commitContexts[pkgParsed.name].versionAtCommit
        if isEmptyOrWhitespace(versionToUse):
          versionToUse = itemRunf.versionString
        versions[pkgParsed.name] = versionToUse
        itemNames.add(pkgParsed.name)
        if itemRunf.isGroup:
          groupNames.add(pkgParsed.name)
        elif isEmptyOrWhitespace(versionToUse):
          raise newException(IOError,
              "could not resolve version for '" & pkgParsed.name & "'")

        installItems.add(InstallWorkItem(name: pkgParsed.name,
            repo: itemRepo, root: root, kTarget: kTarget,
            version: versionToUse, basePackage: basePackage,
            manual: pkgParsed.name in manualInstallList,
            deps: itemRunf.deps, conflicts: itemRunf.conflicts,
            replaces: itemRunf.replaces, isGroup: itemRunf.isGroup,
            keepTransaction: true, progressIndex: installItems.len,
            progressStart: 45, idx: installItems.len))

      var progressRows = initTable[string, int]()
      for idx, name in itemNames:
        progressRows[name] = idx
      progressBegin(itemNames, "")
      var progressClosed = false
      defer:
        if not progressClosed:
          progressRender()
          progressFinish()

      # Snapshot the database before installations can begin. Filesystem
      # journals stay staged until every download and install succeeds.
      var batchState = beginBatchInstall(root)
      var batchSucceeded = false
      defer:
        if batchSucceeded:
          finalizeBatchInstall(batchState)
        else:
          rollbackBatchInstall(batchState)

      let workerLimit = kpkgConfig.getInstallThreads()
      let workerCount = max(1, min(workerLimit, installItems.len))
      installWorkChan.open(installItems.len + workerCount + 4)
      installResultChan.open(installItems.len + 4)
      var workers = newSeq[Thread[void]](workerCount)
      for worker in workers.mitems:
        createThread(worker, installWorkerThread)

      var queued = newSeq[bool](installItems.len)
      var succeeded = newSeq[bool](installItems.len)
      var running: seq[int] = @[]
      var completed = 0
      var inFlight = 0
      var batchFailed = false
      var failureMessage = ""
      var batchDeferredLogs: seq[string] = @[]

      proc archivesReady(item: InstallWorkItem): bool =
        item.isGroup or fileExists(kpkgArchivesDir & "/system/" & kTarget &
            "/" & item.name & "-" & item.version & ".kpkg")

      proc depsSucceeded(item: InstallWorkItem): bool =
        for dep in item.deps:
          let depName = parsePkgInfo(dep).name
          if progressRows.hasKey(depName) and depName != item.name and
              not succeeded[progressRows[depName]]:
            return false
        return true

      proc compatibleWithRunning(item: InstallWorkItem): bool =
        for runningIdx in running:
          let other = installItems[runningIdx]
          if item.name in other.conflicts or other.name in item.conflicts or
              item.name in other.replaces or other.name in item.replaces:
            return false
        return true

      proc queueReady(ignoreDependencies = false): int =
        if batchFailed:
          return 0
        for idx, item in installItems:
          if inFlight >= workerCount:
            break
          if queued[idx] or succeeded[idx] or not archivesReady(item):
            continue
          if not ignoreDependencies and not depsSucceeded(item):
            continue
          if not compatibleWithRunning(item):
            continue
          var work = item
          work.idx = idx
          queued[idx] = true
          running.add(idx)
          inc inFlight
          progressUpdate(work.progressIndex, work.progressStart,
              detail = "installing")
          installWorkChan.send(work)
          inc result

      proc pumpInstalls() =
        while installResultChan.peek() > 0:
          let itemResult = installResultChan.recv()
          batchDeferredLogs.add(itemResult.deferredLogs)
          dec inFlight
          let runningPos = running.find(itemResult.idx)
          if runningPos >= 0:
            running.delete(runningPos)
          if itemResult.ok:
            succeeded[itemResult.idx] = true
            inc completed
          else:
            batchFailed = true
            failureMessage = "installation failed for '" &
                installItems[itemResult.idx].name & "': " & itemResult.errorMsg
        discard queueReady()
        progressRender()

      # downloadParallel invokes pumpInstalls on every progress/completion
      # drain. Atomic archive rename makes newly completed packages visible to
      # this scheduler immediately; independent installs start without waiting
      # for unrelated downloads.
      let downloadOk = downloadBatch(itemNames, binrepos, versions, kTarget,
          offline, forceDownloadPackages, forceDownload,
          ignoreDownloadErrors, combinedProgress = true,
          progressRows = progressRows, skipPackages = groupNames,
          renderUpdates = true, onTick = pumpInstalls)

      while inFlight > 0 or (completed < installItems.len and not batchFailed):
        pumpInstalls()
        if completed >= installItems.len and inFlight == 0:
          break
        if batchFailed:
          if inFlight == 0:
            break
        elif inFlight == 0:
          if not downloadOk:
            batchFailed = true
            failureMessage = "one or more package downloads failed"
            break
          # No ready package with every archive present means a dependency
          # cycle; preserve the previous cycle fallback without deadlocking.
          if queueReady(ignoreDependencies = true) == 0:
            batchFailed = true
            failureMessage = "download pipeline completed with missing archives"
            break
        if inFlight > 0:
          sleep(100)

      # Stop and join installers before committing or rolling back staged
      # filesystem/database transactions.
      for _ in 0 ..< workerCount:
        installWorkChan.send(InstallWorkItem(name: "\x00quit"))
      for worker in workers.mitems:
        joinThread(worker)
      installWorkChan.close()
      installResultChan.close()

      if not downloadOk and not batchFailed:
        batchFailed = true
        failureMessage = "one or more package downloads failed"
      if batchFailed:
        for idx in 0 ..< installItems.len:
          if succeeded[idx]:
            progressUpdate(idx, 100, finished = true, ok = false,
                detail = "rolled back")
        progressRender()
        progressFinish()
        progressClosed = true
        for line in batchDeferredLogs:
          stderr.writeLine(line)
        if batchDeferredLogs.len > 0:
          stderr.flushFile()
        raise newException(IOError, failureMessage)

      progressRender()
      progressFinish()
      progressClosed = true
      for line in batchDeferredLogs:
        stderr.writeLine(line)
      if batchDeferredLogs.len > 0:
        stderr.flushFile()
      batchSucceeded = true

proc install*(promptPackages: seq[string], root = "/", yes: bool = false,
        no: bool = false, forceDownload = false, offline = false,
                downloadOnly = false, ignoreDownloadErrors = false,
                isUpgrade = false, target = "default",
                basePackage = false, exclude: seq[string] = @[],
                disableExcludes: bool = false): int =
  ## Install a package from a binary, from a repository or locally.
  ##
  ## Supports commit-based installation with syntax: package#commit
  ## When a commit hash is specified, the version at that commit is used
  ## to find the binary. If binary not found, suggests using kpkg build.

  if promptPackages.len == 0:
    error("please enter a package name")
    quit(1)

  if not isAdmin():
    error("you have to be root for this action.")
    quit(1)

  setDisableExcludes(disableExcludes)
  addCliExcludePatterns(exclude)

  var deps: seq[string]
  let init = getInit(root)

  var packages: seq[string]

  let fullRootPath = expandFilename(root)

  withInstallCommitContexts(promptPackages, commitCtxs):
    let hasCommit = hasAnyCommit(commitCtxs)

    for i in promptPackages:
      let pkgInfo = parsePkgInfo(i)
      let rawRepo = if pkgInfo.repo != "": pkgInfo.repo else: findPkgRepo(pkgInfo.name)
      let pkgRepo = lastPathPart(rawRepo)
      if isExcluded(pkgInfo.name, pkgRepo):
        if packageExists(pkgInfo.name, root):
          warn "skipping " & pkgInfo.name & ": excluded in kpkg.conf but already installed"
        else:
          fatal "cannot install " & pkgInfo.name & ": package is excluded"
          quit(1)
      packages = packages & pkgInfo.name
      if findPkgRepo(pkgInfo.name&"-"&init) != "":
        packages = packages & (pkgInfo.name&"-"&init)

    var commitForDeps = ""
    var commitRepoForDeps = ""
    var headCacheForDeps = initTable[string, runFile]()

    if hasCommit:
      for name, ctx in commitCtxs:
        if ctx.commit != "":
          commitForDeps = ctx.commit
          commitRepoForDeps = ctx.commitRepo
          headCacheForDeps = ctx.headRunfileCache
          break

    try:
      deps = dephandler(packages, root = root,
              commit = commitForDeps, commitRepo = commitRepoForDeps,
              headRunfileCache = headCacheForDeps)
    except CatchableError:
      error("Dependency detection failed")
      quit(1)

    printReplacesPrompt(deps, root, true)
    printReplacesPrompt(packages, root)

    let binrepos = getConfigValue("Repositories", "binRepos").split(" ")

    deps = deduplicate(deps&packages)

    let gD = getDependents(deps)
    if not isEmptyOrWhitespace(gD.join("")):
      deps = deps&gD

    printPackagesPrompt(deps.join(" "), yes, no, dependents = gD, binary = true)

    var kTarget = target

    if target == "default":
      kTarget = kpkgTarget(root)

    if not (deps.len == 0 and deps == @[""]):
      install_bin(deps, binrepos, fullRootPath, offline,
              downloadOnly = downloadOnly, manualInstallList = promptPackages,
              kTarget = kTarget, forceDownload = forceDownload,
              ignoreDownloadErrors = ignoreDownloadErrors,
              basePackage = basePackage, commitContexts = commitCtxs)

    staleprocs.printStaleWarning()

    info("done")
    return 0
