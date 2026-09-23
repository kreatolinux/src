## Transaction module for atomic package installation with crash recovery.
##
## Provides a journal-based rollback system that records all operations
## during package installation. If installation fails or the system crashes,
## the transaction can be rolled back to restore the previous state.

import os
import json
import times
import std/[tempfiles, sysrand, tables]
import strutils
import posix
import ../commonPaths
import ./barrier
from ../sqlite import validateDatabaseSnapshot, hasPendingHistoryRestore, requireNoPendingHistoryRestore
import ../../../common/logging

type
  OperationType* = enum
    opFileCreated    ## A new file was created
    opFileReplaced   ## An existing file was replaced (backup exists)
    opFileDeleted    ## A file was deleted (backup exists)
    opDirCreated     ## A new directory was created
    opSymlinkCreated ## A new symlink was created
    opDirDeleted     ## An existing directory may be removed during reinstall

  Operation* = object
    kind*: OperationType
    path*: string       ## The target path that was modified
    backupPath*: string ## Path to backup file (for replaced/deleted)
    stagingPath*: string ## Restore-only staging directory, persisted in intent
    timestamp*: float   ## When the operation occurred
    mode*: int          ## Original directory mode, uid and gid
    uid*: int
    gid*: int

  TransactionState* = enum
    tsActive     ## Transaction is in progress
    tsCommitted  ## Transaction completed successfully
    tsRolledBack ## Transaction was rolled back

  Transaction* = ref object
    id*: string
    packageName*: string
    operations*: seq[Operation]
    journalPath*: string
    state*: TransactionState
    root*: string ## The installation root
    historyPath*: string ## Exact durable pending-session identity, never inferred by time.
    journalHandle: File

const journalVersion = "2"

proc getBackupPath*(tx: Transaction, originalPath: string): string =
  ## Generate a unique backup path for a file
  let relativePath = if originalPath.startsWith(tx.root):
    relativePath(originalPath, tx.root)
  else:
    originalPath
  result = kpkgBackupDir & "/" & tx.id & "/" & relativePath

proc parseState(stateStr: string): TransactionState =
  case stateStr
  of "tsCommitted": tsCommitted
  of "tsRolledBack": tsRolledBack
  of "tsActive": tsActive
  else: raise newException(ValueError, "invalid transaction state: " & stateStr)

proc parseOperation(node: JsonNode): Operation =
  ## Parse an operation from JSON.
  result.stagingPath = node.getOrDefault("stagingPath").getStr()
  result.path = node["path"].getStr()
  result.backupPath = node["backupPath"].getStr()
  result.timestamp = node["timestamp"].getFloat()

  let kindStr = node["kind"].getStr()
  case kindStr
  of "opFileCreated": result.kind = opFileCreated
  of "opFileReplaced": result.kind = opFileReplaced
  of "opFileDeleted": result.kind = opFileDeleted
  of "opDirCreated": result.kind = opDirCreated
  of "opSymlinkCreated": result.kind = opSymlinkCreated
  of "opDirDeleted":
    result.kind = opDirDeleted
    result.mode = node["mode"].getInt()
    result.uid = node["uid"].getInt()
    result.gid = node["gid"].getInt()
  else: raise newException(ValueError, "invalid transaction operation: " & kindStr)

proc syncPath*(path: string)
proc syncAncestors*(path: string)
proc durableWrite*(path, contents: string)

proc appendJournalLine(tx: Transaction, line: string) =
  ## Append one durable journal line. Controlled state records use this path
  ## directly to avoid JSON table serialization after worker installs.
  if tx.journalHandle == nil:
    if not open(tx.journalHandle, tx.journalPath, fmAppend):
      raise newException(IOError, "cannot open transaction journal " &
          tx.journalPath)
  tx.journalHandle.writeLine(line)
  tx.journalHandle.flushFile()
  if fsync(cint(getFileHandle(tx.journalHandle))) != 0:
    raiseOSError(osLastError(), "cannot sync transaction journal")

proc appendJournalRecord(tx: Transaction, node: JsonNode) =
  ## Append one durable record instead of rewriting every previous operation.
  ## Keeping the handle open removes repeated open/truncate work; flushing
  ## each record preserves the previous crash-recovery visibility guarantee.
  tx.appendJournalLine($node)

proc appendOperation(tx: Transaction, op: Operation) =
  tx.appendJournalRecord( %* {
    "record": "operation",
    "kind": $op.kind,
    "path": op.path,
    "backupPath": op.backupPath,
    "mode": op.mode,
    "uid": op.uid,
    "gid": op.gid,
    "timestamp": op.timestamp
  })

proc appendState(tx: Transaction) =
  ## State records contain only controlled enum/time values. Write this small
  ## record directly so batch finalization does not depend on JSON table
  ## serialization after worker-thread installs have completed.
  let state = $tx.state
  let timestamp = $epochTime()
  tx.appendJournalLine("{\"record\":\"state\",\"state\":\"" & state &
      "\",\"timestamp\":" & $timestamp & "}")

proc closeJournal*(tx: Transaction) =
  if tx.journalHandle != nil:
    tx.journalHandle.close()
    tx.journalHandle = nil

proc loadTransaction*(journalPath: string): Transaction =
  ## Load both legacy v1 whole-document journals and v2 append-only JSONL.
  ## Stream v2 records instead of duplicating a potentially large journal in
  ## readFile + splitLines allocations during batch finalization.
  var journal: File
  if not open(journal, journalPath, fmRead):
    raise newException(IOError, "cannot open transaction journal " & journalPath)
  defer: journal.close()

  var line: string
  var firstLine = true
  while journal.readLine(line):
    if isEmptyOrWhitespace(line):
      continue
    let record = parseJson(line)
    if firstLine:
      firstLine = false
      if record.hasKey("operations"):
        let legacyId = record["id"].getStr()
        if legacyId.len == 0 or lastPathPart(journalPath) != legacyId & ".journal" or
            '/' in legacyId or '\\' in legacyId:
          raise newException(IOError, "legacy journal identity mismatch: " & journalPath)
        if record.hasKey("version") and record["version"].getStr() != "1":
          raise newException(IOError, "unsupported legacy journal version: " & journalPath)
        # Version 1 compatibility. Legacy journals are one JSON document.
        result = Transaction(id: record["id"].getStr(),
            packageName: record["packageName"].getStr(),
            journalPath: journalPath, root: record["root"].getStr(),
            operations: @[], state: parseState(record["state"].getStr()))
        for opNode in record["operations"]:
          result.operations.add(parseOperation(opNode))
        return

      if record.getOrDefault("record").getStr() != "header":
        raise newException(ValueError, "invalid transaction journal header")
      if record["version"].getStr() != journalVersion:
        raise newException(IOError, "unsupported transaction journal version: " & journalPath)
      let memberId = record["id"].getStr()
      if memberId.len == 0 or memberId in [".", ".."] or '/' in memberId or '\\' in memberId or
          lastPathPart(journalPath) != memberId & ".journal":
        raise newException(IOError, "transaction journal identity mismatch: " & journalPath)
      result = Transaction(id: record["id"].getStr(),
          packageName: record["packageName"].getStr(),
          journalPath: journalPath, root: record["root"].getStr(),
          operations: @[], state: tsActive,
          historyPath: record.getOrDefault("historyPath").getStr())
      continue

    case record.getOrDefault("record").getStr()
    of "operation":
      result.operations.add(parseOperation(record))
    of "state":
      result.state = parseState(record["state"].getStr())
    else:
      raise newException(ValueError, "invalid transaction journal record")

  if firstLine:
    raise newException(ValueError, "empty transaction journal")

proc hasHistoryRestore*(): bool

proc newTransaction*(packageName: string, root: string): Transaction =
  ## Create a new transaction for package installation
  if hasHistoryRestore():
    raise newException(IOError, "history restore requires recovery under the package lock")
  assertNoAbandonedHistory(root)
  let timestamp = epochTime()
  let id = packageName & "-" & $int(timestamp * 1000)

  result = Transaction(
    id: id,
    packageName: packageName,
    operations: @[],
    journalPath: kpkgJournalDir & "/" & id & ".journal",
    state: tsActive,
    root: root,
    historyPath: reserveHistoryMember(root, id, "journal")
  )

  # Create necessary directories (createDir creates parent directories as needed)
  createDir(kpkgJournalDir)
  createDir(kpkgBackupDir)
  # mkdir is exclusive: a collision must never overwrite an earlier history.
  if fileExists(result.journalPath) or symlinkExists(result.journalPath):
    raise newException(IOError, "transaction ID already exists: " & id)
  if posix.mkdir((kpkgBackupDir & "/" & id).cstring, Mode(0o700)) != 0:
    raiseOSError(osLastError(), "cannot reserve transaction ID " & id)

  # Atomically publish the append-only journal header, then retain an
  # append handle for O(1) operation records.
  durableWrite(result.journalPath, $( %* {
    "record": "header",
    "version": journalVersion,
    "id": id,
    "packageName": packageName,
    "state": $tsActive,
    "root": root,
    "historyPath": result.historyPath,
    "timestamp": timestamp
  }) & "\n")
  if not open(result.journalHandle, result.journalPath, fmAppend):
    raise newException(IOError, "cannot open transaction journal " &
        result.journalPath)
  debug "Transaction created: " & id

proc recordFileCreated*(tx: Transaction, path: string) =
  ## Record that a new file was created
  let op = Operation(
    kind: opFileCreated,
    path: path,
    backupPath: "",
    timestamp: epochTime()
  )
  tx.operations.add(op)
  tx.appendOperation(op)

proc recordFileReplaced*(tx: Transaction, path: string, backupPath: string) =
  ## Record that an existing file was replaced
  let op = Operation(
    kind: opFileReplaced,
    path: path,
    backupPath: backupPath,
    timestamp: epochTime()
  )
  tx.operations.add(op)
  tx.appendOperation(op)

proc recordFileDeleted*(tx: Transaction, path: string, backupPath: string) =
  ## Record that a file was deleted
  let op = Operation(
    kind: opFileDeleted,
    path: path,
    backupPath: backupPath,
    timestamp: epochTime()
  )
  tx.operations.add(op)
  tx.appendOperation(op)

proc recordDirDeleted*(tx: Transaction, path: string) =
  ## Save directory metadata before package removal. File backups cannot
  ## restore empty directories, which are also package-owned paths.
  var st: Stat
  if lstat(path.cstring, st) != 0 or not S_ISDIR(st.st_mode):
    raise newException(IOError, "cannot snapshot directory " & path)
  let op = Operation(kind: opDirDeleted, path: path,
      timestamp: epochTime(), mode: int(st.st_mode),
      uid: int(st.st_uid), gid: int(st.st_gid))
  tx.operations.add(op)
  tx.appendOperation(op)

proc recordDirCreated*(tx: Transaction, path: string) =
  ## Record that a new directory was created
  let op = Operation(
    kind: opDirCreated,
    path: path,
    backupPath: "",
    timestamp: epochTime()
  )
  tx.operations.add(op)
  tx.appendOperation(op)

proc recordSymlinkCreated*(tx: Transaction, path: string) =
  ## Record that a new symlink was created
  let op = Operation(
    kind: opSymlinkCreated,
    path: path,
    backupPath: "",
    timestamp: epochTime()
  )
  tx.operations.add(op)
  tx.appendOperation(op)

proc copyHistoryFile*(source, destination: string) =
  ## Copy without consuming the snapshot, including ownership and full mode.
  var st: Stat
  if lstat(source.cstring, st) != 0:
    raiseOSError(osLastError(), "cannot inspect " & source)
  if S_ISLNK(st.st_mode):
    createSymlink(expandSymlink(source), destination)
    if posix.lchown(destination.cstring, st.st_uid, st.st_gid) != 0:
      raiseOSError(osLastError(), "cannot restore symlink ownership " & destination)
  elif S_ISREG(st.st_mode):
    copyFile(source, destination)
    # chown may clear set-id bits, so chmod must run last.
    if posix.chown(destination.cstring, st.st_uid, st.st_gid) != 0:
      raiseOSError(osLastError(), "cannot restore ownership " & destination)
    if posix.chmod(destination.cstring, st.st_mode) != 0:
      raiseOSError(osLastError(), "cannot restore permissions " & destination)
  else:
    raise newException(IOError, "unsupported backup file type: " & source)

proc backupFile*(tx: Transaction, originalPath: string): string =
  ## Reserve a distinct slot even when the same path is backed up repeatedly.
  if not fileExists(originalPath) and not symlinkExists(originalPath):
    return ""
  let base = kpkgBackupDir & "/" & tx.id
  createDir(base)
  var index = tx.operations.len
  var slot: string
  while true:
    slot = base & "/operation-" & $index
    if posix.mkdir(slot.cstring, Mode(0o700)) == 0:
      break
    if osLastError() != OSErrorCode(EEXIST):
      raiseOSError(osLastError(), "cannot reserve backup slot " & slot)
    inc index
  result = slot & "/file"
  copyHistoryFile(originalPath, result)
  if not symlinkExists(result): syncPath(result)
  syncAncestors(parentDir(result))
  debug "Backed up: " & originalPath & " -> " & result

proc recordTreeDeleted*(tx: Transaction, path: string) =
  ## Snapshot a metadata tree without following symlinks. Record parents first
  ## so reverse replay restores children before final directory permissions.
  if symlinkExists(path) or fileExists(path):
    tx.recordFileDeleted(path, tx.backupFile(path))
  elif dirExists(path):
    tx.recordDirDeleted(path)
    for kind, child in walkDir(path):
      tx.recordTreeDeleted(child)

proc isEmptyDir(path: string): bool =
  ## Check if a directory is empty
  for _ in walkDir(path):
    return false
  return true

proc restoresDirectory*(tx: Transaction, path: string): bool =
  ## Reinstall may delete and recreate a directory that existed beforehand.
  let canonical = normalizedPath(absolutePath(path))
  for op in tx.operations:
    if op.kind == opDirDeleted and
        normalizedPath(absolutePath(op.path)) == canonical:
      return true


proc atomicRename(source, destination: cstring): cint {.importc: "rename", header: "<stdio.h>".}

proc syncPath*(path: string) =
  let fd = posix.open(path.cstring, O_RDONLY)
  if fd < 0: raiseOSError(osLastError(), "cannot open for fsync " & path)
  defer: discard posix.close(fd)
  if fsync(fd) != 0: raiseOSError(osLastError(), "cannot fsync " & path)

proc syncAncestors*(path: string) =
  var directory = normalizedPath(absolutePath(path))
  while true:
    syncPath(directory)
    let parent = parentDir(directory)
    if parent == directory or parent.len == 0: break
    directory = parent

proc durableWrite*(path, contents: string) =
  let temporary = path & ".partial"
  writeFile(temporary, contents)
  syncPath(temporary)
  if atomicRename(temporary.cstring, path.cstring) != 0:
    raiseOSError(osLastError(), "cannot publish " & path)
  syncAncestors(parentDir(path))

when defined(historyFaultInjection):
  var historyFaultPoint*: string
  var historyFaultCountdown*: int

proc historyBoundary*(point: string) =
  when defined(historyFaultInjection):
    if historyFaultPoint == point:
      if historyFaultCountdown == 0:
        raise newException(IOError, "injected history failure: " & point)
      dec historyFaultCountdown

proc durableParents(path: string) =
  if dirExists(path): return
  durableParents(parentDir(path))
  createDir(path)
  syncPath(path)
  syncPath(parentDir(path))

proc newRestoreStaging*(path: string): string =
  result = parentDir(path) / ".kpkg-restore-"
  for value in urandom(16): result.add(toHex(value, 2))
  if fileExists(result) or symlinkExists(result) or dirExists(result):
    raise newException(IOError, "restore staging collision")

proc atomicHistoryCopy*(source, destination: string, stagingPath = "") =
  ## Atomic visibility for this file only; never consume the snapshot.
  durableParents(parentDir(destination))
  let staging = if stagingPath.len > 0: stagingPath
    else: createTempDir(".kpkg-restore-", "", parentDir(destination))
  if stagingPath.len > 0:
    if symlinkExists(staging): raise newException(IOError, "restore staging replaced by symlink")
    if dirExists(staging): removeDir(staging)
    if posix.mkdir(staging.cstring, Mode(0o700)) != 0:
      raiseOSError(osLastError(), "cannot create restore staging")
  let temporary = staging / "file"
  try:
    historyBoundary("copy")
    copyHistoryFile(source, temporary)
    historyBoundary("metadata")
    if not symlinkExists(temporary): syncPath(temporary)
    syncPath(staging)
    historyBoundary("rename")
    if atomicRename(temporary.cstring, destination.cstring) != 0:
      raiseOSError(osLastError(), "cannot restore " & destination)
    syncPath(parentDir(destination))
    historyBoundary("renamed")
  finally:
    removeDir(staging)
    syncPath(parentDir(destination))

proc restoreHistoryOperation*(op: Operation) =
  case op.kind:
  of opFileCreated, opSymlinkCreated:
    if symlinkExists(op.path) or fileExists(op.path): removeFile(op.path)
    elif dirExists(op.path):
      raise newException(IOError, "cannot remove file replaced by directory: " & op.path)
    if dirExists(parentDir(op.path)): syncPath(parentDir(op.path))
  of opFileReplaced, opFileDeleted:
    atomicHistoryCopy(op.backupPath, op.path, op.stagingPath)
  of opDirDeleted:
    if symlinkExists(op.path) or fileExists(op.path):
      raise newException(IOError, "cannot restore directory over file/symlink: " & op.path)
    durableParents(op.path)
    if posix.chown(op.path.cstring, Uid(op.uid), Gid(op.gid)) != 0 or
        posix.chmod(op.path.cstring, Mode(op.mode)) != 0:
      raiseOSError(osLastError(), "cannot restore directory metadata " & op.path)
    syncPath(op.path)
    historyBoundary("metadata")
  of opDirCreated:
    if symlinkExists(op.path) or fileExists(op.path):
      raise newException(IOError, "cannot remove directory replaced by file/symlink: " & op.path)
    if dirExists(op.path):
      if not isEmptyDir(op.path):
        raise newException(IOError, "cannot remove nonempty history directory: " & op.path)
      removeDir(op.path)
      syncPath(parentDir(op.path))

proc restoreField(node: JsonNode, key: string, kind: JsonNodeKind): JsonNode =
  if node.kind != JObject or not node.hasKey(key) or node[key].kind != kind:
    raise newException(IOError, "invalid history restore field: " & key)
  node[key]

proc restoreCanonical(path: string): string =
  if path.len == 0 or not path.isAbsolute or '\0' in path or
      normalizedPath(path) != path:
    raise newException(IOError, "noncanonical history restore path: " & path)
  path

proc restoreWithin(path, base: string): bool =
  path.startsWith(base.strip(leading = false, trailing = true, chars = {'/'}) & "/")

proc validateHistoryRestorePlan*(marker: string, plan: JsonNode) =
  ## No writes, mkdirs, cleanup, or cursor publication until the whole suffix
  ## has passed schema, identity, source, staging and reverse-state checks.
  if restoreField(plan, "version", JInt).getInt() != 1:
    raise newException(IOError, "unsupported history restore version")
  let root = restoreCanonical(restoreField(plan, "root", JString).getStr())
  let steps = restoreField(plan, "steps", JArray)
  let cursor = restoreField(plan, "cursor", JInt).getInt()
  if cursor < 0 or cursor > steps.len:
    raise newException(IOError, "invalid history recovery cursor")
  if parentDir(restoreCanonical(marker)) != normalizedPath(kpkgJournalDir) or
      symlinkExists(marker):
    raise newException(IOError, "invalid history restore marker")
  if symlinkExists(marker & ".partial") or dirExists(marker & ".partial"):
    raise newException(IOError, "unsafe history restore cursor staging")
  var markerAncestor = parentDir(marker)
  while markerAncestor.len > 0:
    if symlinkExists(markerAncestor):
      raise newException(IOError, "unsafe history restore marker ancestor")
    let next = parentDir(markerAncestor)
    if next == markerAncestor: break
    markerAncestor = next
  let history = root / "var/lib/kpkg/history"
  var sessions: seq[string]
  var journals: seq[string]
  var operations: seq[Operation]
  var batches: seq[string]
  var session = ""
  var matchingEntry = false
  if plan.hasKey("session"):
    session = restoreCanonical(restoreField(plan, "session", JString).getStr())
    if parentDir(session) != history or marker != kpkgJournalDir / (lastPathPart(session) & ".restore"):
      raise newException(IOError, "restore session mismatch")
    sessions.add(session)
  # Legacy undo plans identify their exact entries through entry-state writes.
  for step in steps:
    let kind = restoreField(step, "type", JString).getStr()
    if kind == "write":
      let path = restoreCanonical(restoreField(step, "path", JString).getStr())
      if lastPathPart(path) == "entry.json" and parentDir(parentDir(path)) == history:
        let entry = parseJson(readFile(path))
        if restoreField(entry, "root", JString).getStr() != root:
          raise newException(IOError, "restore entry root mismatch")
        sessions.add(parentDir(path))
        if marker == kpkgJournalDir / (restoreField(entry, "id", JString).getStr() & ".restore"):
          matchingEntry = true
  if session.len == 0 and not marker.endsWith(".journal.restore") and not matchingEntry:
    raise newException(IOError, "restore marker has no matching history entry")
  if marker.endsWith(".journal.restore"):
    journals.add(marker[0 ..< marker.len - ".restore".len])
  for directory in sessions:
    let metadata = if fileExists(directory / "pending.json"): directory / "pending.json"
      else: directory / "entry.json"
    let data = if directory == session and plan.hasKey("sessionMetadata"):
      restoreField(plan, "sessionMetadata", JObject)
      else: parseJson(readFile(metadata))
    if directory == session and fileExists(directory / "pending.json") and
        data != parseJson(readFile(directory / "pending.json")):
      raise newException(IOError, "restore session metadata differs from pending evidence")
    if restoreField(data, "root", JString).getStr() != root:
      raise newException(IOError, "restore metadata root mismatch")
    if data.hasKey("members"):
      for value in restoreField(data, "members", JArray):
        let id = restoreField(value, "id", JString).getStr()
        let kind = restoreField(value, "kind", JString).getStr()
        if id.len == 0 or '/' in id or '\\' in id or id in [".", ".."]:
          raise newException(IOError, "invalid restore member ID")
        if kind == "journal": journals.add(kpkgJournalDir / (id & ".journal"))
        elif kind == "batch": batches.add(kpkgJournalDir / ("batch-" & id & ".batch"))
        else: raise newException(IOError, "invalid restore member kind")
    elif data.hasKey("ids"):
      for value in restoreField(data, "ids", JArray):
        if value.kind != JString: raise newException(IOError, "invalid restore member")
        let id = value.getStr()
        if id.len == 0 or '/' in id or '\\' in id or id in [".", ".."]:
          raise newException(IOError, "invalid restore member ID")
        journals.add(kpkgJournalDir / (id & ".journal"))
    elif directory == session:
      # Pending recovery journals must carry the exact session identity.
      for journal in walkFiles(kpkgJournalDir / "*.journal"):
        let tx = loadTransaction(journal)
        if tx.historyPath == session: journals.add(journal)
    else: raise newException(IOError, "missing restore membership")
  for journal in journals:
    let tx = loadTransaction(journal)
    if normalizedPath(absolutePath(tx.root)) != root or
        (session.len > 0 and tx.historyPath != session):
      raise newException(IOError, "restore journal identity mismatch")
    for op in tx.operations: operations.add(op)
  proc sourceAncestors(path: string) =
    var ancestor = parentDir(path)
    while ancestor.len > 0:
      if symlinkExists(ancestor) or not dirExists(ancestor):
        raise newException(IOError, "unsafe recovery evidence ancestor: " & ancestor)
      let next = parentDir(ancestor)
      if next == ancestor: break
      ancestor = next
  for journal in journals: sourceAncestors(journal)
  for directory in sessions:
    sourceAncestors(directory / "entry.json")
  var state = initTable[string, char]() # absent, regular/link, directory
  proc nodeKind(path: string): char =
    if state.hasKey(path): return state[path]
    var st: Stat
    if lstat(path.cstring, st) != 0:
      if osLastError() != OSErrorCode(ENOENT): raiseOSError(osLastError())
      return 'a'
    if S_ISDIR(st.st_mode): return 'd'
    if S_ISREG(st.st_mode): return 'f'
    if S_ISLNK(st.st_mode): return 'l'
    raise newException(IOError, "unsupported recovery destination: " & path)
  proc parents(path: string) =
    var ancestor = parentDir(path)
    while ancestor.len > 0:
      if nodeKind(ancestor) notin {'a', 'd'}:
        raise newException(IOError, "unsafe recovery ancestor: " & ancestor)
      state[ancestor] = 'd'
      let next = parentDir(ancestor)
      if next == ancestor: break
      ancestor = next
  proc staging(path, destination: string) =
    discard restoreCanonical(path)
    let name = lastPathPart(path)
    if parentDir(path) != parentDir(destination) or not name.startsWith(".kpkg-restore-") or
        name.len != ".kpkg-restore-".len + 32:
      raise newException(IOError, "invalid restore staging location")
    for ch in name[".kpkg-restore-".len .. ^1]:
      if ch notin {'0'..'9', 'A'..'F', 'a'..'f'}:
        raise newException(IOError, "invalid restore staging name")
    if symlinkExists(path) or fileExists(path):
      raise newException(IOError, "unsafe restore staging")
    if dirExists(path):
      for kind, child in walkDir(path):
        if child != path / "file" or kind notin {pcFile, pcLinkToFile, pcLinkToDir}:
          raise newException(IOError, "foreign restore staging contents")
  proc fileTarget(path: string, removing = false) =
    parents(path)
    if nodeKind(path) == 'd': raise newException(IOError, "file restore destination is directory: " & path)
    state[path] = if removing: 'a' else: 'f'
  for i in cursor ..< steps.len:
    let step = steps[i]
    let kind = restoreField(step, "type", JString).getStr()
    case kind
    of "file":
      let data = restoreField(step, "operation", JObject)
      for key in ["kind", "path", "backupPath"]: discard restoreField(data, key, JString)
      if not data.hasKey("timestamp") or data["timestamp"].kind notin {JInt, JFloat}:
        raise newException(IOError, "invalid operation timestamp")
      let op = parseOperation(data)
      discard restoreCanonical(op.path)
      if not restoreWithin(op.path, root): raise newException(IOError, "restore target outside root")
      var member = false
      for original in operations:
        if original.kind == op.kind and original.path == op.path and
            original.backupPath == op.backupPath and original.mode == op.mode and
            original.uid == op.uid and original.gid == op.gid: member = true
      if session.len > 0 and op.path == root / "etc/ld.so.cache" and
          op.backupPath == session / "ld.so.cache" and op.kind in {opFileCreated, opFileReplaced}: member = true
      if not member: raise newException(IOError, "restore operation is not a session member")
      parents(op.path)
      case op.kind
      of opFileReplaced, opFileDeleted:
        discard restoreCanonical(op.backupPath)
        sourceAncestors(op.backupPath)
        staging(restoreField(data, "stagingPath", JString).getStr(), op.path)
        var st: Stat
        if lstat(op.backupPath.cstring, st) != 0 or (not S_ISREG(st.st_mode) and not S_ISLNK(st.st_mode)):
          raise newException(IOError, "missing or unsupported recovery backup")
        fileTarget(op.path)
        if S_ISLNK(st.st_mode): state[op.path] = 'l'
      of opFileCreated, opSymlinkCreated: fileTarget(op.path, true)
      of opDirDeleted:
        for key in ["mode", "uid", "gid"]:
          if restoreField(data, key, JInt).getInt() < 0: raise newException(IOError, "invalid directory metadata")
        if nodeKind(op.path) notin {'a', 'd'}: raise newException(IOError, "directory restore destination is file")
        state[op.path] = 'd'
      of opDirCreated:
        if nodeKind(op.path) notin {'a', 'd'}: raise newException(IOError, "directory removal destination is file")
        if dirExists(op.path) and not symlinkExists(op.path):
          for _, child in walkDir(op.path):
            if nodeKind(child) != 'a': raise newException(IOError, "untracked child in restore directory")
        for child, value in state:
          if parentDir(child) == op.path and value != 'a': raise newException(IOError, "restored child in removed directory")
        state[op.path] = 'a'
    of "database", "copy":
      let path = restoreCanonical(restoreField(step, "path", JString).getStr())
      let source = restoreField(step, "source", JString).getStr()
      if path != root / kpkgDbPath: raise newException(IOError, "foreign database target")
      if source.len > 0:
        discard restoreCanonical(source)
        if lastPathPart(source) != "before.sqlite" or parentDir(source) notin sessions:
          raise newException(IOError, "foreign database snapshot")
        sourceAncestors(source)
        if symlinkExists(source): raise newException(IOError, "symlink database snapshot")
        validateDatabaseSnapshot(source)
        staging(restoreField(step, "stagingPath", JString).getStr(), path)
      elif kind == "copy": raise newException(IOError, "empty database copy source")
      fileTarget(path, source.len == 0)
      for suffix in ["-wal", "-shm"]: fileTarget(path & suffix, true)
    of "write", "remove":
      let path = restoreCanonical(restoreField(step, "path", JString).getStr())
      var permitted = false
      if kind == "write":
        let contents = restoreField(step, "contents", JString).getStr()
        permitted = path in journals or (parentDir(path) in sessions and lastPathPart(path) in ["entry.json", "recovered.json"])
        if path in journals:
          let existing = readFile(path).strip()
          let proposed = contents.strip()
          let first = parseJson(existing.splitLines()[0])
          if first.hasKey("operations"):
            var expected = parseJson(existing)
            expected["state"] = %($tsRolledBack)
            if parseJson(proposed) != expected:
              raise newException(IOError, "invalid legacy journal state write")
          elif proposed != existing:
            if not proposed.startsWith(existing & "\n"):
              raise newException(IOError, "restore journal write changes evidence")
            let addition = proposed[existing.len .. ^1].strip()
            let record = parseJson(addition)
            if restoreField(record, "record", JString).getStr() != "state" or
                restoreField(record, "state", JString).getStr() != $tsRolledBack:
              raise newException(IOError, "invalid restore journal state")
        else:
          let data = parseJson(contents)
          if restoreField(data, "root", JString).getStr() != root: raise newException(IOError, "foreign restore metadata write")
          if lastPathPart(path) == "entry.json":
            var expected = parseJson(readFile(path))
            expected["state"] = %"undone"
            if data != expected: raise newException(IOError, "restore entry write changes evidence")
          elif restoreField(data, "state", JString).getStr() != "recovered":
            raise newException(IOError, "invalid recovered metadata state")
        if symlinkExists(path) or symlinkExists(path & ".partial") or dirExists(path & ".partial"):
          raise newException(IOError, "unsafe restore write target")
      else:
        permitted = session.len > 0 and path == session / "pending.json"
        if path in batches and session.len > 0:
          if fileExists(path):
            let batch = parseJson(readFile(path))
            permitted = restoreField(batch, "root", JString).getStr() == root and
              restoreField(batch, "historyPath", JString).getStr() == session
          else: permitted = true # deletion may have completed before cursor fsync
      if not permitted: raise newException(IOError, "foreign restore metadata target")
      fileTarget(path, kind == "remove")
    else: raise newException(IOError, "invalid history recovery operation")

proc replayHistoryRestore*(marker: string) =
  var plan = parseJson(readFile(marker))
  validateHistoryRestorePlan(marker, plan)
  let steps = plan["steps"]
  var cursor = plan["cursor"].getInt()
  while cursor < steps.len:
    let step = steps[cursor]
    case step["type"].getStr()
    of "file": restoreHistoryOperation(parseOperation(step["operation"]))
    of "database":
      historyBoundary("database")
      let path = step["path"].getStr()
      let source = step["source"].getStr()
      # This entire phase repeats if interrupted, including sidecar removal.
      for suffix in ["-wal", "-shm"]:
        let sidecar = path & suffix
        if fileExists(sidecar) or symlinkExists(sidecar): removeFile(sidecar)
      syncPath(parentDir(path))
      historyBoundary("database-sidecars")
      if source.len > 0:
        atomicHistoryCopy(source, path, step["stagingPath"].getStr())
      else:
        if fileExists(path) or symlinkExists(path): removeFile(path)
        syncPath(parentDir(path))
    of "copy":
      historyBoundary("database")
      # Older intents used separate sidecar steps. Repeat cleanup here too.
      for suffix in ["-wal", "-shm"]:
        let sidecar = step["path"].getStr() & suffix
        if fileExists(sidecar) or symlinkExists(sidecar): removeFile(sidecar)
      atomicHistoryCopy(step["source"].getStr(), step["path"].getStr(),
          step.getOrDefault("stagingPath").getStr())
    of "remove":
      let path = step["path"].getStr()
      if fileExists(path) or symlinkExists(path): removeFile(path)
      if dirExists(parentDir(path)): syncPath(parentDir(path))
    of "write":
      historyBoundary("state")
      durableWrite(step["path"].getStr(), step["contents"].getStr())
    else: raise newException(IOError, "invalid history recovery operation")
    historyBoundary("applied")
    inc cursor
    plan["cursor"] = %cursor
    durableWrite(marker, $plan)
    historyBoundary("cursor")
  removeFile(marker)
  syncPath(parentDir(marker))

proc recoverHistoryRestores*() =
  if not dirExists(kpkgJournalDir): return
  for marker in walkFiles(kpkgJournalDir / "*.restore"):
    replayHistoryRestore(marker)
  if hasPendingHistoryRestore():
    raise newException(IOError, "unreadable or unsupported history restore marker")

proc hasHistoryRestore*(): bool =
  hasPendingHistoryRestore()

proc restoreHistoryFiles*(tx: Transaction) =
  ## Strict history restore. Leave state, journal and snapshots unchanged.
  if tx.state != tsCommitted:
    raise newException(ValueError, "history restore requires a committed transaction")
  # Check every required snapshot before making any filesystem changes.
  for op in tx.operations:
    if op.kind in {opFileReplaced, opFileDeleted}:
      var st: Stat
      if op.backupPath == "" or lstat(op.backupPath.cstring, st) != 0:
        raise newException(IOError, "missing history backup: " & op.backupPath)
      if not S_ISREG(st.st_mode) and not S_ISLNK(st.st_mode):
        raise newException(IOError, "unsupported history backup: " & op.backupPath)
  let marker = tx.journalPath & ".restore"
  if fileExists(marker):
    replayHistoryRestore(marker)
    return
  if hasHistoryRestore():
    raise newException(IOError, "another history restore requires recovery")
  var steps = newJArray()
  for i in countdown(tx.operations.high, 0):
    let op = tx.operations[i]
    if op.kind == opDirCreated and tx.restoresDirectory(op.path): continue
    if op.kind in {opFileReplaced, opFileDeleted}:
      if not symlinkExists(op.backupPath): syncPath(op.backupPath)
      syncAncestors(parentDir(op.backupPath))
    steps.add(%* {"type": "file", "operation": {
      "kind": $op.kind, "path": op.path, "backupPath": op.backupPath,
      "stagingPath": newRestoreStaging(op.path),
      "timestamp": op.timestamp, "mode": op.mode, "uid": op.uid, "gid": op.gid}})
  durableWrite(marker, $(%* {"version": 1, "root": tx.root, "cursor": 0, "steps": steps}))
  replayHistoryRestore(marker)

proc markHistoryUndone*(tx: Transaction) =
  ## Record successful history undo without deleting snapshots.
  if tx.state != tsCommitted:
    raise newException(ValueError, "history undo requires a committed transaction")
  tx.state = tsRolledBack
  try:
    tx.appendState()
  except:
    tx.state = tsCommitted
    raise
  finally:
    tx.closeJournal()

proc rollback*(tx: Transaction) =
  ## Undo all operations in reverse order to restore previous state
  if tx.state != tsActive:
    debug "Transaction " & tx.id & " is not active, cannot rollback"
    return

  debug "Rolling back transaction: " & tx.id

  # Process operations in reverse order
  for i in countdown(tx.operations.high, 0):
    let op = tx.operations[i]

    try:
      case op.kind:
      of opFileCreated:
        # Remove the created file
        if fileExists(op.path) or symlinkExists(op.path):
          removeFile(op.path)
          debug "Rollback: removed created file " & op.path

      of opSymlinkCreated:
        # Remove the created symlink
        if symlinkExists(op.path):
          removeFile(op.path)
          debug "Rollback: removed created symlink " & op.path

      of opFileReplaced:
        # Restore from backup
        if op.backupPath != "" and (fileExists(op.backupPath) or symlinkExists(
            op.backupPath)):
          if fileExists(op.path) or symlinkExists(op.path):
            removeFile(op.path)
          let destDir = parentDir(op.path)
          if not dirExists(destDir):
            createDir(destDir)
          atomicHistoryCopy(op.backupPath, op.path)
          debug "Rollback: restored replaced file " & op.path
        else:
          raise newException(IOError, "missing rollback backup: " & op.backupPath)

      of opFileDeleted:
        # Restore from backup
        if op.backupPath != "" and (fileExists(op.backupPath) or symlinkExists(
            op.backupPath)):
          if fileExists(op.path) or symlinkExists(op.path):
            removeFile(op.path)
          let destDir = parentDir(op.path)
          if not dirExists(destDir):
            createDir(destDir)
          atomicHistoryCopy(op.backupPath, op.path)
          debug "Rollback: restored deleted file " & op.path
        else:
          raise newException(IOError, "missing rollback backup: " & op.backupPath)

      of opDirDeleted:
        # File backups may recreate parents, but cannot recreate empty leaves.
        # Never follow a replacement symlink while restoring metadata.
        if symlinkExists(op.path) or fileExists(op.path):
          raise newException(IOError, "cannot restore directory over file/symlink")
        createDir(op.path)
        if posix.chown(op.path.cstring, Uid(op.uid), Gid(op.gid)) != 0 or
            posix.chmod(op.path.cstring, Mode(op.mode)) != 0:
          raise newException(IOError, "cannot restore directory metadata")
        debug "Rollback: restored deleted directory " & op.path

      of opDirCreated:
        # Remove directory if empty
        if dirExists(op.path) and isEmptyDir(op.path):
          removeDir(op.path)
          debug "Rollback: removed created directory " & op.path

    except CatchableError as e:
      raise newException(IOError, "Rollback operation failed for " & op.path & ": " & e.msg)

  tx.state = tsRolledBack
  tx.appendState()
  tx.closeJournal()

  # Clean up backup directory for this transaction
  let txBackupDir = kpkgBackupDir & "/" & tx.id
  if tx.historyPath.len == 0 and dirExists(txBackupDir):
    try:
      removeDir(txBackupDir)
    except:
      discard

  debug "Rollback complete for transaction: " & tx.id

proc commit*(tx: Transaction) =
  ## Mark transaction complete and retain its journal and backups for history.
  if tx.state != tsActive:
    debug "Transaction " & tx.id & " is not active, cannot commit"
    return

  debug "Committing transaction: " & tx.id

  tx.state = tsCommitted
  tx.appendState()
  tx.closeJournal()

  debug "Transaction committed: " & tx.id


proc getActiveTransactions*(): seq[Transaction]

proc beginBatchJournal*(id, root, dbPath, dbBackupPath: string,
        hadDatabase: bool): string =
  ## Create a crash-recovery marker for a multi-package installation. The
  ## marker is written atomically after the metadata snapshot exists.
  createDir(kpkgJournalDir)
  result = kpkgJournalDir & "/batch-" & id & ".batch"
  let data = %* {
    "version": journalVersion,
    "id": id,
    "root": root,
    "dbPath": dbPath,
    "dbBackupPath": dbBackupPath,
    "hadDatabase": hadDatabase,
    "state": "active",
    "historyPath": reserveHistoryMember(root, id, "batch")
  }
  durableWrite(result, $data)

proc finishBatchJournal*(path: string) =
  if path != "" and fileExists(path):
    removeFile(path)

proc pendingHistoryAtRoot(root: string): bool =
  let base = normalizedPath(absolutePath(if root.len == 0: "/" else: root)) / "var/lib/kpkg/history"
  if not dirExists(base): return
  for kind, path in walkDir(base):
    if kind in {pcDir, pcLinkToDir} and
        (fileExists(path / "pending.json") or symlinkExists(path / "pending.json")):
      return true

proc recoverBatchJournals*(): bool =
  ## Recover batches that crashed after staging one or more package
  ## transactions. Called before SQLite is opened by kpkg.
  if not dirExists(kpkgJournalDir):
    return false
  # Validate the complete batch set before any rollback work.
  for marker in walkFiles(kpkgJournalDir & "/batch-*.batch"):
    try:
      let data = parseJson(readFile(marker))
      if data.getOrDefault("historyPath").getStr().len > 0 or
          pendingHistoryAtRoot(data["root"].getStr()): continue
      if data.kind != JObject or data["dbPath"].kind != JString or
          data["dbBackupPath"].kind != JString or data["hadDatabase"].kind != JBool or
          data["root"].kind != JString or data["state"].getStr() != "active":
        raise newException(IOError, "invalid batch recovery schema")
      if data["hadDatabase"].getBool():
        validateDatabaseSnapshot(data["dbBackupPath"].getStr())
    except CatchableError as e:
      raise newException(IOError, "invalid batch recovery marker " & marker & ": " & e.msg)
  for marker in walkFiles(kpkgJournalDir & "/batch-*.batch"):
    try:
      let data = parseJson(readFile(marker))
      if data.getOrDefault("historyPath").getStr().len > 0 or
          pendingHistoryAtRoot(data["root"].getStr()): continue
      let dbPath = data["dbPath"].getStr()
      let backupPath = data["dbBackupPath"].getStr()
      let hadDatabase = data["hadDatabase"].getBool()
      if hadDatabase: validateDatabaseSnapshot(backupPath)
      # Package journals are still active because batch finalization is the
      # last operation. Roll them back before restoring metadata.
      for tx in getActiveTransactions():
        if tx.historyPath.len == 0 and not pendingHistoryAtRoot(tx.root): tx.rollback()
      if dbPath != "":
        for suffix in ["-wal", "-shm"]:
          let sidecar = dbPath & suffix
          if fileExists(sidecar):
            removeFile(sidecar)
        if hadDatabase:
          atomicHistoryCopy(backupPath, dbPath)
        elif fileExists(dbPath) or symlinkExists(dbPath):
          removeFile(dbPath)
          syncPath(parentDir(dbPath))
      removeFile(marker)
      syncPath(parentDir(marker))
      if backupPath != "" and fileExists(backupPath):
        removeFile(backupPath)
      result = true
      warn "Recovered incomplete batch installation from " & marker
    except CatchableError as e:
      raise newException(IOError, "Failed to recover batch journal " & marker & ": " & e.msg)

proc getActiveTransactions*(): seq[Transaction] =
  ## Find all incomplete transactions (for crash recovery)
  result = @[]

  if not dirExists(kpkgJournalDir):
    return

  for journalFile in walkFiles(kpkgJournalDir & "/*.journal"):
    try:
      let tx = loadTransaction(journalFile)
      if tx.state == tsActive:
        result.add(tx)
    except CatchableError as e:
      raise newException(IOError, "Failed to load transaction from " & journalFile & ": " & e.msg)

proc recoverFromCrash*(): bool =
  ## Check for and recover from incomplete transactions.
  ## Returns true if any recovery was performed.
  discard getActiveTransactions() # Corrupt journals must stop recovery before mutation.
  recoverHistoryRestores()
  result = recoverBatchJournals()
  let activeTxs = getActiveTransactions()

  if activeTxs.len == 0:
    return result

  warn "Found " & $activeTxs.len & " incomplete transaction(s) from previous run"

  for tx in activeTxs:
    if tx.historyPath.len > 0 or pendingHistoryAtRoot(tx.root): continue # Explicit history recover owns files AND database.
    warn "Rolling back incomplete transaction: " & tx.id & " (package: " &
        tx.packageName & ")"
    try:
      tx.rollback()
    except CatchableError as e:
      raise newException(IOError, "Failed to rollback transaction " & tx.id & ": " & e.msg)

  return true

proc cleanupOldRolledBackTransactions*(maxAgeDays: int = 7) =
  ## Clean up old rolled-back journals; committed history is retained.
  if not dirExists(kpkgJournalDir):
    return

  if hasHistoryRestore():
    raise newException(IOError, "history restore requires recovery before cleanup")
  let maxAgeSeconds = float(maxAgeDays * 24 * 60 * 60)
  let now = epochTime()

  for journalFile in walkFiles(kpkgJournalDir & "/*.journal"):
    try:
      let tx = loadTransaction(journalFile)
      if tx.state == tsRolledBack and (tx.historyPath.len == 0 or
          not fileExists(tx.historyPath / "pending.json")):
        # Check age based on last operation timestamp
        var lastOpTime = 0.0
        for op in tx.operations:
          if op.timestamp > lastOpTime:
            lastOpTime = op.timestamp

        if lastOpTime > 0 and (now - lastOpTime) > maxAgeSeconds:
          removeFile(journalFile)
          debug "Cleaned up old journal: " & journalFile
    except:
      discard

  # Clean up orphaned backup directories
  if dirExists(kpkgBackupDir):
    for kind, path in walkDir(kpkgBackupDir):
      if kind == pcDir:
        let txId = lastPathPart(path)
        let journalPath = kpkgJournalDir & "/" & txId & ".journal"
        if not fileExists(journalPath):
          try:
            removeDir(path)
            debug "Cleaned up orphaned backup directory: " & path
          except:
            discard
