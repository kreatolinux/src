import os
import osproc
import strutils
import sequtils
import parsecfg
import tables
import ../modules/sqlite
import ../modules/config
import ../../common/logging
import ../modules/lockfile
import ../modules/isolation
import ../modules/checksums
import ../modules/runparser
import ../modules/processes
import ../modules/downloader
import ../modules/dephandler
import ../modules/libarchive
import ../modules/commonTasks
import ../modules/commonPaths
import ../modules/removeInternal
import ../modules/transaction
import ../modules/run3/run3
import ../modules/staleprocs
import ../modules/builder/commitctx

setControlCHook(ctrlc)

type
  FileToInstall = object
    srcPath: string  # Path in the extracted temp directory
    destPath: string # Final destination path in root
    relPath: string  # Relative path for database
    checksum: string # Blake2 checksum
    isDir: bool      # Whether this is a directory
    isSymlink: bool  # Whether this is a symlink

proc validateExtractedFiles(kpkgInstallTemp: string, extractTarball: seq[string],
                            dict: Config, pkg: runFile): seq[FileToInstall] =
  ## Validate all extracted files and return a list of files to install.
  ## This is the "check" phase - no side effects on the target system.
  result = @[]

  for file in extractTarball:
    if "pkgsums.ini" == lastPathPart(file) or "pkgInfo.ini" == lastPathPart(file):
      continue

    let relPath = relativePath(file, kpkgInstallTemp)
    let srcPath = kpkgInstallTemp & "/" & file
    let value = dict.getSectionValue("", relPath)

    let isSymlink = symlinkExists(srcPath)
    let isRegularFile = fileExists(srcPath) and not isSymlink
    let isDir = dirExists(srcPath) and not isSymlink

    # Validate checksums for regular files
    if isRegularFile:
      if isEmptyOrWhitespace(value):
        debug file
        fatal("package sums invalid - file exists but no checksum in manifest")

      let actualSum = getSum(srcPath, "b2")
      if actualSum != value:
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

    # Remove existing file if it wasn't backed up (e.g., from a replaced package)
    if fileExists(f.destPath) or symlinkExists(f.destPath):
      removeFile(f.destPath)

    if f.isSymlink:
      # Copy symlink
      let target = expandSymlink(f.srcPath)
      createSymlink(target, f.destPath)
      tx.recordSymlinkCreated(f.destPath)
      debug "Installed symlink: " & f.relPath
    else:
      # Copy regular file with permissions
      copyFileWithPermissionsAndOwnership(f.srcPath, f.destPath)
      tx.recordFileCreated(f.destPath)
      debug "Installed file: " & f.relPath

proc installPkg*(repo: string, package: string, root: string, runf = runFile(
        isParsed: false), manualInstallList: seq[string], isUpgrade = false,
                kTarget = kpkgTarget(root), ignorePostInstall = false,
                umount = true, disablePkgInfo = false, ignorePreInstall = false,
                basePackage = false, version = "", tarballPath = "") =
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
    fatal("Unknown error while trying to parse package on repository, possibly broken repo?")

  debug "installPkg ran, repo: '"&repo&"', package: '"&package&"', root: '"&root&"', manualInstallList: '"&manualInstallList.join(" ")&"'"

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
      if executeFunctionByName(ctx, pkg.run3Data.parsed, preupgradeFunc) != 0:
        fatal("preupgrade failed")

  # Run preinstall hook (before any changes)
  if not packageExists(package, root):
    let preinstallFunc = resolveHookFunction(pkg.run3Data.parsed, "preinstall", package)
    if preinstallFunc != "":
      if executeFunctionByName(ctx, pkg.run3Data.parsed, preinstallFunc) != 0:
        if ignorePreInstall:
          warn "preinstall failed"
        else:
          fatal("preinstall failed")

  let isGroup = pkg.isGroup

  # Check for conflicts
  for i in pkg.conflicts:
    if packageExists(i, root):
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

  setCurrentDir(kpkgArchivesDir)

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

        if kTarget != kpkgTarget(root):
          removeInternal(i, root, initCheck = false)
        else:
          removeInternal(i, root)

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
      if kTarget != kpkgTarget(root):
        removeInternal(package, root, ignoreReplaces = true,
                noRunfile = true, initCheck = false)
      else:
        removeInternal(package, root, ignoreReplaces = true,
                noRunfile = false, depCheck = false)

    discard existsOrCreateDir(root&"/var")
    discard existsOrCreateDir(root&"/var/cache")
    discard existsOrCreateDir(root&kpkgCacheDir)

    if not isGroup:
      var extractTarball: seq[string]
      let kpkgInstallTemp = kpkgTempDir1&"/install-"&package
      if dirExists(kpkgInstallTemp):
        removeDir(kpkgInstallTemp)

      createDir(kpkgInstallTemp)
      setCurrentDir(kpkgInstallTemp)

      # Phase 1: Extract tarball
      try:
        extractTarball = extract(tarball, kpkgInstallTemp)
      except Exception:
        when defined(release):
          tx.rollback()
          fatal("extracting the tarball failed for "&package)
        else:
          tx.rollback()
          removeLockfile()
          raise getCurrentException()

      var dict = loadConfig(kpkgInstallTemp&"/pkgsums.ini")

      # Phase 2: Validate all files (no side effects)
      var filesToInstall = validateExtractedFiles(kpkgInstallTemp,
          extractTarball, dict, pkg)

      # Update destination paths
      for i in 0..<filesToInstall.len:
        filesToInstall[i].destPath = root & "/" & filesToInstall[i].relPath

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

      # Phase 6: Update database (after all files are installed)
      var mI = false
      if package in manualInstallList:
        info "Setting as manually installed"
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

    else:
      # Register group packages in the database
      var mI = false
      if package in manualInstallList:
        info "Setting as manually installed"
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

    # Run ldconfig afterwards for any new libraries.
    let ldconfigCmd = if root == "/": "ldconfig" else: "ldconfig -r " & root
    discard execProcess(ldconfigCmd)

    if dirExists(kpkgOverlayPath) and dirExists(kpkgMergedPath) and umount:
      discard umountOverlay(error = "unmounting overlays")

    # Phase 7: Run postinstall (BEFORE cleanup so rollback is possible)
    let postinstallFunc = resolveHookFunction(pkg.run3Data.parsed,
        "postinstall", package)
    if postinstallFunc != "":
      if executeFunctionByName(ctx, pkg.run3Data.parsed, postinstallFunc) != 0:
        if ignorePostInstall:
          warn "postinstall failed"
        else:
          tx.rollback()
          rollbackTransaction(root)
          fatal("postinstall failed")

    # Phase 8: Run postupgrade
    if isUpgradeActual:
      let postupgradeFunc = resolveHookFunction(pkg.run3Data.parsed,
          "postupgrade", package)
      if postupgradeFunc != "":
        if executeFunctionByName(ctx, pkg.run3Data.parsed, postupgradeFunc) != 0:
          tx.rollback()
          rollbackTransaction(root)
          fatal("postupgrade failed")

    # Phase 9: Commit transaction (removes backups, deletes journal)
    tx.commit()

    # Phase 10: Cleanup temp directories (AFTER successful commit)
    when defined(release):
      removeDir(kpkgTempDir1)
      removeDir(kpkgTempDir2)

    for i in pkg.optdeps:
      info(i)

  except CatchableError:
    # Rollback on any error
    error "Installation failed, rolling back..."
    tx.rollback()
    raise

proc canDownloadBinary*(package: string, version: string, binrepos: seq[string],
        kTarget: string): bool =
  ## Check if a binary is downloadable from any mirror (without actually downloading)
  ## Uses a quick HEAD request via curl to check existence

  let tarball = package & "-" & version & ".kpkg"

  for binrepo in binrepos:
    let url = "https://" & binrepo & "/archives/system/" & kTarget & "/" & tarball
    let (_, exitCode) = execCmdEx("curl -sfI " & quoteShell(url) & " 2>/dev/null")
    if exitCode == 0:
      debug "canDownloadBinary: Binary '" & tarball & "' found at " & binrepo
      return true

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

  setCurrentDir(kpkgArchivesDir)
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
    info "Tarball already exists for '"&package&"', not gonna download again"
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
    for i in packages:
      let pkgParsed = parsePkgInfo(i)
      var fdownload = false
      if i in forceDownloadPackages or forceDownload:
        fdownload = true

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

      down_bin(pkgParsed.name, binrepos, root, offline, fdownload,
              ignoreDownloadErrors = ignoreDownloadErrors, kTarget = kTarget,
              version = versionToUse, commit = commitToUse)

    if not downloadOnly:
      for i in packages:
        let pkgParsed = parsePkgInfo(i)
        var versionToUse = pkgParsed.version

        if pkgParsed.commit != "" and pkgParsed.name in commitContexts and
            commitContexts[pkgParsed.name].commit != "":
          versionToUse = commitContexts[pkgParsed.name].versionAtCommit

        installPkg(pkgParsed.repo, pkgParsed.name, root,
                manualInstallList = manualInstallList, kTarget = kTarget,
                basePackage = basePackage, version = versionToUse)
        info "Installation for "&i&" complete"

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
