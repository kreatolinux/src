## Transaction module for atomic package installation with crash recovery.
## 
## Provides a journal-based rollback system that records all operations
## during package installation. If installation fails or the system crashes,
## the transaction can be rolled back to restore the previous state.

import os
import json
import times
import strutils
import sequtils
import commonPaths
import ../../common/logging

type
  OperationType* = enum
    opFileCreated    ## A new file was created
    opFileReplaced   ## An existing file was replaced (backup exists)
    opFileDeleted    ## A file was deleted (backup exists)
    opDirCreated     ## A new directory was created
    opSymlinkCreated ## A new symlink was created

  Operation* = object
    kind*: OperationType
    path*: string       ## The target path that was modified
    backupPath*: string ## Path to backup file (for replaced/deleted)
    timestamp*: float   ## When the operation occurred

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
  else: tsActive

proc parseOperation(node: JsonNode): Operation =
  ## Parse an operation from JSON.
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
  else: result.kind = opFileCreated

proc appendJournalRecord(tx: Transaction, node: JsonNode) =
  ## Append one durable record instead of rewriting every previous operation.
  ## Keeping the handle open removes repeated open/truncate work; flushing
  ## each record preserves the previous crash-recovery visibility guarantee.
  if tx.journalHandle == nil:
    if not open(tx.journalHandle, tx.journalPath, fmAppend):
      raise newException(IOError, "cannot open transaction journal " &
          tx.journalPath)
  tx.journalHandle.writeLine($node)
  tx.journalHandle.flushFile()

proc appendOperation(tx: Transaction, op: Operation) =
  tx.appendJournalRecord(%* {
    "record": "operation",
    "kind": $op.kind,
    "path": op.path,
    "backupPath": op.backupPath,
    "timestamp": op.timestamp
  })

proc appendState(tx: Transaction) =
  tx.appendJournalRecord(%* {
    "record": "state",
    "state": $tx.state,
    "timestamp": epochTime()
  })

proc closeJournal(tx: Transaction) =
  if tx.journalHandle != nil:
    tx.journalHandle.close()
    tx.journalHandle = nil

proc loadTransaction(journalPath: string): Transaction =
  ## Load both legacy v1 whole-document journals and v2 append-only JSONL.
  let content = readFile(journalPath)
  let records = content.splitLines().filterIt(not isEmptyOrWhitespace(it))
  if records.len == 0:
    raise newException(ValueError, "empty transaction journal")

  let first = parseJson(records[0])
  if first.hasKey("operations"):
    # Version 1 compatibility.
    result = Transaction(id: first["id"].getStr(),
        packageName: first["packageName"].getStr(), journalPath: journalPath,
        root: first["root"].getStr(), operations: @[],
        state: parseState(first["state"].getStr()))
    for opNode in first["operations"]:
      result.operations.add(parseOperation(opNode))
    return

  if first.getOrDefault("record").getStr() != "header":
    raise newException(ValueError, "invalid transaction journal header")
  result = Transaction(id: first["id"].getStr(),
      packageName: first["packageName"].getStr(), journalPath: journalPath,
      root: first["root"].getStr(), operations: @[], state: tsActive)
  for i in 1 ..< records.len:
    let record = parseJson(records[i])
    case record.getOrDefault("record").getStr()
    of "operation":
      result.operations.add(parseOperation(record))
    of "state":
      result.state = parseState(record["state"].getStr())
    else:
      discard

proc newTransaction*(packageName: string, root: string): Transaction =
  ## Create a new transaction for package installation
  let timestamp = epochTime()
  let id = packageName & "-" & $int(timestamp * 1000)

  result = Transaction(
    id: id,
    packageName: packageName,
    operations: @[],
    journalPath: kpkgJournalDir & "/" & id & ".journal",
    state: tsActive,
    root: root
  )

  # Create necessary directories (createDir creates parent directories as needed)
  createDir(kpkgLibDir)
  createDir(kpkgJournalDir)
  createDir(kpkgBackupDir)
  createDir(kpkgBackupDir & "/" & id)

  # Atomically publish the append-only journal header, then retain an
  # append handle for O(1) operation records.
  let partialJournal = result.journalPath & ".partial"
  writeFile(partialJournal, $(%* {
    "record": "header",
    "version": journalVersion,
    "id": id,
    "packageName": packageName,
    "state": $tsActive,
    "root": root,
    "timestamp": timestamp
  }) & "\n")
  moveFile(partialJournal, result.journalPath)
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

proc backupFile*(tx: Transaction, originalPath: string): string =
  ## Backup a file before replacing/deleting it. Returns the backup path.
  if not fileExists(originalPath) and not symlinkExists(originalPath):
    return ""

  let backupPath = tx.getBackupPath(originalPath)

  # For symlinks, use a .symlink suffix to avoid conflicts with directories
  # This can happen when a package contains both a symlink (e.g., /usr/sbin -> /sbin)
  # and files inside that path (e.g., /usr/sbin/unix_chkpwd)
  var actualBackupPath = backupPath
  if symlinkExists(originalPath):
    actualBackupPath = backupPath & ".symlink"

  let backupDir = parentDir(actualBackupPath)

  if not dirExists(backupDir):
    createDir(backupDir)

  # Use copy instead of move to preserve the original during installation
  # The original will be overwritten/removed later

  # Remove existing backup if it exists (handles re-runs or conflicts)
  if fileExists(actualBackupPath) or symlinkExists(actualBackupPath):
    removeFile(actualBackupPath)

  if symlinkExists(originalPath):
    let target = expandSymlink(originalPath)
    createSymlink(target, actualBackupPath)
  else:
    copyFile(originalPath, actualBackupPath)
    # Preserve permissions
    setFilePermissions(actualBackupPath, getFilePermissions(originalPath))

  debug "Backed up: " & originalPath & " -> " & actualBackupPath
  return actualBackupPath

proc isEmptyDir(path: string): bool =
  ## Check if a directory is empty
  for _ in walkDir(path):
    return false
  return true

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
        if fileExists(op.path):
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
          moveFile(op.backupPath, op.path)
          debug "Rollback: restored replaced file " & op.path

      of opFileDeleted:
        # Restore from backup
        if op.backupPath != "" and (fileExists(op.backupPath) or symlinkExists(
            op.backupPath)):
          if fileExists(op.path) or symlinkExists(op.path):
            removeFile(op.path)
          let destDir = parentDir(op.path)
          if not dirExists(destDir):
            createDir(destDir)
          moveFile(op.backupPath, op.path)
          debug "Rollback: restored deleted file " & op.path

      of opDirCreated:
        # Remove directory if empty
        if dirExists(op.path) and isEmptyDir(op.path):
          removeDir(op.path)
          debug "Rollback: removed created directory " & op.path

    except CatchableError as e:
      warn "Rollback operation failed for " & op.path & ": " & e.msg

  tx.state = tsRolledBack
  tx.appendState()
  tx.closeJournal()

  # Clean up backup directory for this transaction
  let txBackupDir = kpkgBackupDir & "/" & tx.id
  if dirExists(txBackupDir):
    try:
      removeDir(txBackupDir)
    except:
      discard

  debug "Rollback complete for transaction: " & tx.id

proc commit*(tx: Transaction) =
  ## Mark transaction as complete and clean up backups
  if tx.state != tsActive:
    debug "Transaction " & tx.id & " is not active, cannot commit"
    return

  debug "Committing transaction: " & tx.id

  tx.state = tsCommitted
  tx.appendState()
  tx.closeJournal()

  # Clean up backup files - they're no longer needed
  let txBackupDir = kpkgBackupDir & "/" & tx.id
  if dirExists(txBackupDir):
    try:
      removeDir(txBackupDir)
      debug "Cleaned up backup directory: " & txBackupDir
    except CatchableError as e:
      warn "Failed to clean up backup directory: " & e.msg

  # Remove the journal file
  if fileExists(tx.journalPath):
    try:
      removeFile(tx.journalPath)
      debug "Removed journal file: " & tx.journalPath
    except CatchableError as e:
      warn "Failed to remove journal file: " & e.msg

  debug "Transaction committed: " & tx.id


proc getActiveTransactions*(): seq[Transaction]

proc beginBatchJournal*(id, root, dbPath, dbBackupPath: string,
        hadDatabase: bool): string =
  ## Create a crash-recovery marker for a multi-package installation. The
  ## marker is written atomically after the metadata snapshot exists.
  createDir(kpkgLibDir)
  createDir(kpkgJournalDir)
  result = kpkgJournalDir & "/batch-" & id & ".batch"
  let partial = result & ".partial"
  let data = %* {
    "version": journalVersion,
    "id": id,
    "root": root,
    "dbPath": dbPath,
    "dbBackupPath": dbBackupPath,
    "hadDatabase": hadDatabase,
    "state": "active"
  }
  writeFile(partial, $data)
  moveFile(partial, result)

proc finishBatchJournal*(path: string) =
  if path != "" and fileExists(path):
    removeFile(path)

proc recoverBatchJournals*(): bool =
  ## Recover batches that crashed after staging one or more package
  ## transactions. Called before SQLite is opened by kpkg.
  if not dirExists(kpkgJournalDir):
    return false
  for marker in walkFiles(kpkgJournalDir & "/batch-*.batch"):
    try:
      let data = parseJson(readFile(marker))
      let dbPath = data["dbPath"].getStr()
      let backupPath = data["dbBackupPath"].getStr()
      let hadDatabase = data["hadDatabase"].getBool()
      # Package journals are still active because batch finalization is the
      # last operation. Roll them back before restoring metadata.
      for tx in getActiveTransactions():
        tx.rollback()
      if dbPath != "":
        if fileExists(dbPath):
          removeFile(dbPath)
        for suffix in ["-wal", "-shm"]:
          let sidecar = dbPath & suffix
          if fileExists(sidecar):
            removeFile(sidecar)
        if hadDatabase and fileExists(backupPath):
          copyFile(backupPath, dbPath)
      if backupPath != "" and fileExists(backupPath):
        removeFile(backupPath)
      removeFile(marker)
      result = true
      warn "Recovered incomplete batch installation from " & marker
    except CatchableError as e:
      warn "Failed to recover batch journal " & marker & ": " & e.msg

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
      warn "Failed to load transaction from " & journalFile & ": " & e.msg

proc recoverFromCrash*(): bool =
  ## Check for and recover from incomplete transactions.
  ## Returns true if any recovery was performed.
  result = recoverBatchJournals()
  let activeTxs = getActiveTransactions()

  if activeTxs.len == 0:
    return result

  warn "Found " & $activeTxs.len & " incomplete transaction(s) from previous run"

  for tx in activeTxs:
    warn "Rolling back incomplete transaction: " & tx.id & " (package: " &
        tx.packageName & ")"
    try:
      tx.rollback()
    except CatchableError as e:
      error "Failed to rollback transaction " & tx.id & ": " & e.msg

  return true

proc cleanupOldTransactions*(maxAgeDays: int = 7) =
  ## Clean up old committed/rolledback transaction journals and backups
  if not dirExists(kpkgJournalDir):
    return

  let maxAgeSeconds = float(maxAgeDays * 24 * 60 * 60)
  let now = epochTime()

  for journalFile in walkFiles(kpkgJournalDir & "/*.journal"):
    try:
      let tx = loadTransaction(journalFile)
      if tx.state != tsActive:
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
