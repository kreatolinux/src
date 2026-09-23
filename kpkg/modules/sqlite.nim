import std/os
import commonPaths
import ../../common/logging
import ./checksums
import std/strutils
import std/options
import std/posix
import norm/[model, sqlite]

# Coordinate live SQLite readers with exclusive package mutation/recovery.
proc hasPendingHistoryRestore*(): bool =
  if dirExists(kpkgJournalDir):
    # Include malformed markers and symlinks: recovery must decide validity.
    for kind, path in walkDir(kpkgJournalDir, checkDir = true):
      if path.endsWith(".restore"):
        return true

proc requireNoPendingHistoryRestore*() =
  if hasPendingHistoryRestore():
    raise newException(IOError,
      "history restore is pending; recover it before accessing the live database")

const lockfilePath* {.strdefine.} = "/tmp/kpkg.lock"
var mutationLockOwned {.threadvar.}: bool
var liveGuardFd {.threadvar.}: cint
var liveGuardHeld {.threadvar.}: bool
var noFollow {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint
proc guardFlock(fd, operation: cint): cint {.importc: "flock",
    header: "<sys/file.h>".}

proc ownsMutationLock*(): bool = mutationLockOwned

proc setMutationLockOwned*(owned: bool) =
  ## Caller holds the exclusive flock; workers must close before final release.
  mutationLockOwned = owned

proc acquireLiveDatabaseGuard*() =
  if liveGuardHeld or mutationLockOwned:
    return
  let fd = posix.open((lockfilePath & ".guard").cstring,
      O_CREAT or O_RDONLY or O_CLOEXEC or noFollow, Mode(0o644))
  if fd < 0:
    raiseOSError(osLastError(), "cannot open live database guard")
  if guardFlock(fd, 1 or 4) != 0: # LOCK_SH | LOCK_NB
    discard posix.close(fd)
    raise newException(IOError, "package mutation blocks live database access")
  liveGuardFd = fd
  liveGuardHeld = true

proc releaseLiveDatabaseGuard*() =
  if liveGuardHeld:
    discard guardFlock(liveGuardFd, 8) # LOCK_UN
    discard posix.close(liveGuardFd)
    liveGuardHeld = false


type
  Package* = ref object of Model
    name*: string
    version*: string
    release*: string
    epoch*: string
    deps*: string
    bdeps*: string
    manualInstall*: bool
    isGroup*: bool
    backup*: string
    replaces*: string
    license*: string
    desc*: string
    basePackage*: bool

  File* = ref object of Model
    path*: string
    blake2Checksum*: string
    package*: Package


# Each install worker owns an independent SQLite connection/state. SQLite
# serializes writers at the database-file level; WAL plus busy_timeout lets
# concurrent package workers wait briefly instead of failing immediately.
var kpkgDb {.threadvar.}: DbConn
var connOn {.threadvar.}: bool
var currentRoot {.threadvar.}: string
var inTransaction {.threadvar.}: bool


func newPackageInternal(name = "", version = "", deps = "", bdeps = "",
        backup = "", replaces = "", license = "", desc = "", release = "",
            epoch = "",
        manualInstall = false, isGroup = false, basePackage = false): Package =
  # Initializes a new Package.
  Package(name: name, version: version, release: release, epoch: epoch,
          deps: deps, bdeps: bdeps, manualInstall: manualInstall,
          isGroup: isGroup, backup: backup, replaces: replaces,
          license: license,
          desc: desc, basePackage: basePackage)

func newFileInternal(path = "", checksum = "", package = newPackageInternal()): File =
  # Initializes a new Package.
  File(path: path, blake2Checksum: checksum, package: package)

proc packageFieldNames*(): seq[string] =
  ## Fields accepted by getPackageByValue(). Keep reflection beside the model.
  let package = newPackageInternal()
  for fieldName, value in package[].fieldPairs:
    result.add(fieldName)
  result.add("listFiles")

proc fileFieldNames*(): seq[string] =
  ## Fields accepted by getFileByValue(), including its checksum alias.
  let file = newFileInternal()
  for fieldName, value in file[].fieldPairs:
    result.add(fieldName)
    if fieldName == "blake2Checksum":
      result.add("b2Sum")

proc closeDb*() =
  # Wrapper for close.
  if connOn:
    close kpkgDb
    connOn = false
    currentRoot = ""
    inTransaction = false
  releaseLiveDatabaseGuard()

proc rootCheck(root: string) =
  # The shared lease excludes restore intent publication for this connection.
  if connOn and currentRoot != root:
    closeDb()
  acquireLiveDatabaseGuard()
  try:
    requireNoPendingHistoryRestore()
  except:
    closeDb()
    raise
  # Root checks (internal)
  # Only close/reopen if the root path actually changed
  if connOn and currentRoot == root:
    return

  # A failed open or migration must not leave an orphan shared lease.
  var initialized = false
  defer:
    if not initialized:
      closeDb()

  var firstTime = false

  if not fileExists(root&"/"&kpkgDbPath):
    createDir(root&"/"&kpkgLibDir)
    firstTime = true

  kpkgDb = open(root&"/"&kpkgDbPath, "", "", "")
  connOn = true
  currentRoot = root
  # Wait up to five minutes for another package transaction to finish.
  kpkgDb.exec(sql"PRAGMA busy_timeout = 300000")
  # WAL permits readers while a worker commits its package metadata.
  try:
    kpkgDb.exec(sql"PRAGMA journal_mode = WAL")
  except DbError:
    discard

  if firstTime:
    kpkgDb.createTables(newFileInternal())
  else:
    # Handle schema migrations for existing databases
    # Check if license column exists, if not add it
    try:
      kpkgDb.exec(sql"SELECT license FROM Package LIMIT 1")
    except DbError:
      debug "Adding missing 'license' column to Package table"
      kpkgDb.exec(sql"ALTER TABLE Package ADD COLUMN license TEXT NOT NULL DEFAULT ''")
  initialized = true


proc beginTransaction*(root: string) =
  ## Begin a database transaction. All subsequent operations will be
  ## part of this transaction until commit or rollback is called.
  rootCheck(root)
  if not inTransaction:
    kpkgDb.exec(sql"BEGIN TRANSACTION")
    inTransaction = true
    debug "SQLite transaction started"

proc commitTransaction*(root: string) =
  ## Commit the current transaction, making all changes permanent.
  rootCheck(root)
  if inTransaction:
    kpkgDb.exec(sql"COMMIT")
    inTransaction = false
    debug "SQLite transaction committed"

proc rollbackTransaction*(root: string) =
  ## Rollback the current transaction, discarding all changes.
  rootCheck(root)
  if inTransaction:
    kpkgDb.exec(sql"ROLLBACK")
    inTransaction = false
    debug "SQLite transaction rolled back"

proc isInTransaction*(): bool =
  ## Check if a transaction is currently active.
  return inTransaction

template withDbTransaction*(root: string, body: untyped) =
  ## Execute a block of code within a database transaction.
  ## If the block completes successfully, the transaction is committed.
  ## If an exception occurs, the transaction is rolled back.
  beginTransaction(root)
  try:
    body
    commitTransaction(root)
  except:
    rollbackTransaction(root)
    raise


proc getFileByValue*(file = newFileInternal(), field = ""): string =
  # Get a file field by value.
  # usage: getPackageByValue(package, "name")

  # thanks to getchoo to make me not yanderedev this shit
  result = "File("&file.path&"):"
  for fieldName, value in file[].fieldPairs:
    if isEmptyOrWhitespace(field):
      when value is bool:
        result.add("\n\t" & fieldName & " is " & $value)
      elif value is Package:
        result.add("\n\t" & fieldName & " is Package(" & value.name & ")")
      else:
        if fieldName == "blake2Checksum":
          # Add an alias
          result.add("\n\t" & "blake2Checksum | b2Sum" & " '" &
                  $value & "'")
        else:
          result.add("\n\t" & fieldName & " '" & $value & "'")
    elif field == fieldName or (fieldName == "blake2Checksum" and field == "b2Sum"):
      when value is Package:
        return("\n\t" & fieldName & " is Package(" & value.name & ")")
      else:
        return $value

proc getFileByValueAll*(root: string, field = "") =
  # Return getPackageByValue for all packages.
  rootCheck(root)

  var files = @[newFileInternal()]
  kpkgDb.selectAll(files)

  for f in files:
    echo getFileByValue(f, field)&"\n"

proc newPackage*(name, version, release, epoch, deps, bdeps, backup, replaces,
        license, desc: string, manualInstall, isGroup, basePackage: bool,
        root: string): Package =
  # Initialize a new Package (wrapper)
  rootCheck(root)
  debug "newPackage ran"
  var res = newPackageInternal(name, version, deps, bdeps, backup, replaces,
          license, desc, release, epoch, manualInstall, isGroup, basePackage)
  kpkgDb.insert(res)
  return res

proc newFile*(path, checksum: string, package: Package, root: string) =
  # Initialize a File (wrapper)
  rootCheck(root)
  var res = newFileInternal(path, checksum, package)
  kpkgDb.insert(res)

proc pkgSumstoSQL*(file: string, package: Package, root: string) =
  # Converts pkgSums.ini into SQL
  #
  # pkgsums.ini is the transport format into the database: its entries
  # become the authoritative File rows, and verification afterwards only
  # consults sqlite. The archive metadata files themselves are inputs to
  # the installer, not package payload, so they must never be registered.
  const archiveMeta = ["\"" & "pkgsums.ini" & "\"", "\"pkgInfo.ini\"",
          "pkgsums.ini", "pkgInfo.ini"]
  for line in lines file:
    let splittedLine = line.split("=")
    if splittedLine.len != 2:
      if splittedLine[0] in archiveMeta:
        continue
      newFile(splittedLine[0], "", package, root)
    else:
      if splittedLine[0] in archiveMeta:
        continue
      newFile(splittedLine[0], splittedLine[1], package, root)

proc isReplaced*(name: string, root = "/"): tuple[replaced: bool,
        package: Package] =
  # Checks if a package is "replaced" or not.
  rootCheck(root)

  # feels wrong for some reason, hmu if theres a better way -kreatoo
  var packages = @[newPackageInternal()]
  kpkgDb.selectAll(packages)

  for package in packages:
    if name in package.replaces.split("!!k!!"):
      return (true, package)

  return (false, newPackageInternal())

proc packageExistsExact*(name: string, root = "/"): bool =
  ## Check for an exact package row, without replacement-provider fallback.
  rootCheck(root)
  return kpkgDb.exists(Package, "name = ?", name)

proc getPackageExact*(name: string, root: string): Package =
  ## Get an exact package row, without replacement-provider fallback.
  rootCheck(root)
  var package = newPackageInternal()
  kpkgDb.select(package, "name = ?", name)
  return package

proc packageExists*(name: string, root = "/"): bool =
  # Check if a package exists in the database.
  rootCheck(root)

  try:
    if isReplaced(name, root).replaced:
      return true
    else:
      let res = kpkgDb.exists(Package, "name = ?", name)
      return res
  except CatchableError as e:
    debug "packageExists exception for '"&name&"' at '"&root&"': "&e.msg
    return false

proc getPackage*(name: string, root: string): Package =
  # Gets Package from package name.
  rootCheck(root)

  debug "getPackage ran, name: '"&name&"', root: '"&root&"'"

  if not packageExists(name, root):
    logging.error("internal: package '"&name&"' doesn't exist at '"&root&"', but attempted to getPackage anyway")
    quit(1)

  var package = newPackageInternal()

  package = isReplaced(name, root).package

  if isEmptyOrWhitespace(package.name):
    kpkgDb.select(package, "name = ?", name)

  return package

proc isAuthoritativeFileOwner*(path: string, package: Package,
        root: string): bool =
  ## A shared path can be listed by multiple packages (notably info/dir).
  ## The newest File row is the authoritative owner after package installs.
  rootCheck(root)
  let row = kpkgDb.getRow(sql"SELECT package FROM File WHERE path = ? ORDER BY id DESC LIMIT 1", path)
  if row.isNone:
    return false
  result = $row.get()[0] == $package.id

proc getFile*(path: string, root: string): File =
  # Gets File from path.
  rootCheck(root)

  debug "getFile ran, path: '"&path&"', root: '"&root&"'"

  #if not packageExists(name, root):
  #    err("internal: package '"&name&"' doesn't exist at '"&root&"', but attempted to getPackage anyway", false)

  var file = newFileInternal()

  kpkgDb.select(file, "path = ?", "\""&path&"\"")

  return file

proc getFilesPackage*(package: Package, root: string): seq[File] =
  # Gets all File types from a package.
  # Recommended way to get the list of files from a package.
  rootCheck(root)

  var files = @[newFileInternal()]
  kpkgDb.select(files, "package = ?", package)

  return files


proc rmPackage*(name: string, root: string) =
  # Remove a package from the database.
  rootCheck(root)
  try:
    var package = getPackage(name, root)

    var file = @[newFileInternal()]
    kpkgDb.select(file, "package = ?", package)

    kpkgDb.delete(package)
    kpkgDb.delete(file)
  except NotFoundError:
    discard


proc getListPackages*(root = "/"): seq[string] =
  # Returns a list of packages.

  rootCheck(root)

  var packages = @[newPackageInternal()]
  kpkgDb.selectAll(packages)

  var packageList: seq[string]

  # feels wrong for some reason, hmu if theres a better way -kreatoo
  for p in packages:
    packageList = packageList&p.name

  return packageList

proc getListPackagesType*(root = "/"): seq[Package] =
  # Returns a list of packages.
  # Similar to getListPackages, but returns a seq[Package] instead.

  rootCheck(root)

  var packages = @[newPackageInternal()]
  kpkgDb.selectAll(packages)

  return packages

proc refreshPackageChecksums*(packageName, root: string) =
  ## Post-install hooks may generate or rewrite files owned by this package
  ## (for example Python's pip scripts and RECORD). Refresh only this
  ## package's regular-file rows after hooks complete; SQLite remains the
  ## authoritative installed-state manifest.
  let package = getPackage(packageName, root)
  rootCheck(root)
  for file in getFilesPackage(package, root):
    let relative = file.path.replace("\"", "")
    let fullPath = root & "/" & relative
    if fileExists(fullPath) and not symlinkExists(fullPath):
      let checksum = getSum(fullPath, "b2")
      kpkgDb.exec(sql"UPDATE File SET blake2Checksum = ? WHERE id = ?",
          checksum, $file.id)

proc newPackageFromRoot*(root, package, destdir: string) =
  ## Copy package metadata from root to destdir without creating duplicate
  ## rows when overlapping dependency closures contain the same package.
  rootCheck(root)
  let sourcePkg = getPackage(package, root)

  rootCheck(destdir)
  if packageExistsExact(sourcePkg.name, destdir):
    return

  var copiedPkg = newPackageInternal(sourcePkg.name, sourcePkg.version,
          sourcePkg.deps, sourcePkg.bdeps, sourcePkg.backup,
          sourcePkg.replaces, sourcePkg.license, sourcePkg.desc,
          sourcePkg.release, sourcePkg.epoch, sourcePkg.manualInstall,
          sourcePkg.isGroup, sourcePkg.basePackage)
  kpkgDb.insert(copiedPkg)

proc getListFiles*(packageName: string, root: string, package = getPackage(
        packageName, root)): seq[string] =
  # Gives a list of files.
  # comparable to list_files in kpkg <v6.

  debug "getListFiles: entered for package '"&packageName&"' at root '"&root&"'"
  rootCheck(root)
  debug "getListFiles: rootCheck completed"

  var files = @[newFileInternal()]
  debug "getListFiles: about to select files from db"
  kpkgDb.select(files, "package = ?", package)
  debug "getListFiles: db select completed, got " & $files.len & " files"

  var listFiles: seq[string]

  for file in files:
    listFiles = listFiles&file.path.replace("\"", "")

  debug "getListFiles: returning " & $listFiles.len & " file paths"
  return listFiles

proc getPackageByValue*(package = newPackageInternal(), field = ""): string =
  # Get a package field by value.
  # usage: getPackageByValue(package, "name")

  if field == "listFiles":
    return getListFiles(package.name, "/", package).join("\n")

  # thanks to getchoo to make me not yanderedev this shit
  result = "Package("&package.name&"):"
  for fieldName, value in package[].fieldPairs:
    if isEmptyOrWhitespace(field):
      when value is bool:
        result.add("\n\t" & fieldName & " is " & $value)
      else:
        result.add("\n\t" & fieldName & " '" & $value & "'")
    elif field == fieldName:
      return $value
  result.add("\n\tlistFiles listFiles("&package.name&")")

proc getPackageByValueAll*(root: string, field = "") =
  # Return getPackageByValue for all packages.
  rootCheck(root)

  var packages = @[newPackageInternal()]
  kpkgDb.selectAll(packages)

  for f in packages:
    echo getPackageByValue(f, field)&"\n"

proc snapshotDatabase*(root, destination: string) =
  ## SQLite creates a consistent standalone image, including WAL contents.
  rootCheck(root)
  if inTransaction:
    raise newException(IOError, "cannot snapshot an active SQLite transaction")
  kpkgDb.exec(sql"VACUUM INTO ?", destination)

proc databaseFingerprint*(root: string): string =
  ## Stable logical representation independent of SQLite page layout/WAL.
  rootCheck(root)
  for tableName in ["Package", "File"]:
    for row in kpkgDb.getAllRows(SqlQuery("SELECT * FROM " & tableName &
        " ORDER BY id")):
      result.add($row & "\n")

when defined(macosx):
  const snapshotSqliteLib = "libsqlite3(|.0).dylib"
elif defined(windows):
  const snapshotSqliteLib = "sqlite3.dll"
else:
  const snapshotSqliteLib = "libsqlite3.so(|.0)"

proc openSnapshotV2(filename: cstring, db: var DbConn, flags: cint,
    vfs: cstring): cint {.cdecl, dynlib: snapshotSqliteLib,
    importc: "sqlite3_open_v2".}

proc openDatabaseSnapshot(path: string): DbConn =
  ## No live-root access, schema migration, WAL recovery, or sidecar creation.
  var st: Stat
  if lstat(path.cstring, st) != 0 or not S_ISREG(st.st_mode):
    raise newException(IOError, "history database snapshot is not a regular file: " & path)
  if st.st_size < 100:
    raise newException(IOError, "history database snapshot is truncated: " & path)
  # Encode reserved URI bytes, retaining slash separators in the absolute path.
  var uri = "file:"
  for ch in absolutePath(path):
    if ch in {'a'..'z', 'A'..'Z', '0'..'9', '/', '-', '_', '.', '~'}:
      uri.add(ch)
    else:
      uri.add("%" & toHex(ord(ch), 2))
  uri.add("?mode=ro&immutable=1")
  # SQLITE_OPEN_READONLY | SQLITE_OPEN_URI. Do not rely on global URI settings.
  if openSnapshotV2(uri.cstring, result, 0x00000001 or 0x00000040, nil) != 0:
    if result != nil:
      close(result)
    raise newException(IOError, "cannot open history database snapshot: " & path)

proc validateDatabaseSnapshot*(path: string) =
  ## Validate standalone retained bytes, ignoring any accompanying WAL/SHM.
  try:
    let db = openDatabaseSnapshot(path)
    defer: close(db)
    let rows = db.getAllRows(sql"PRAGMA integrity_check")
    if rows.len != 1 or rows[0].len != 1 or rows[0][0].s != "ok":
      raise newException(IOError, "corrupt history database snapshot: " & path)
    # An unrelated but valid SQLite image is not a package database snapshot.
    discard db.getAllRows(sql"SELECT id, name, version, release, epoch FROM Package LIMIT 0")
    discard db.getAllRows(sql"SELECT id, path, blake2Checksum, package FROM File LIMIT 0")
  except DbError as exc:
    raise newException(IOError, "invalid history database snapshot: " & path &
        ": " & exc.msg)

proc snapshotPackageVersions*(path: string): seq[tuple[name, version, release,
    epoch: string]] =
  ## Read a retained snapshot without opening or migrating the live database.
  let db = openDatabaseSnapshot(path)
  defer: close(db)
  for row in db.getAllRows(sql"SELECT name, version, release, epoch FROM Package ORDER BY name"):
    result.add((row[0].s, row[1].s, row[2].s, row[3].s))
