## Persistent history for package-managed files and SQLite metadata.
## Hooks and overlapping parallel file writes are explicit rollback barriers.
import std/[os, json, times, algorithm, tables, posix, strutils]
import ./[main, barrier]
import ../[sqlite, commonPaths, checksums, versioncmp]

type
  HistoryEntry* = object
    id*: string
    packages*: seq[string]
    state*: string
    action*: string
    rollbackReason*: string
    path*: string
    timestamp*: float
  HistorySession* = ref object
    path*: string
    root*: string
    hadDatabase*: bool

proc canonicalRoot(root: string): string =
  normalizedPath(absolutePath(if root.len == 0: "/" else: root))

proc historyDir(root: string): string = canonicalRoot(root) / "var/lib/kpkg/history"

proc writeAtomic(path: string, data: JsonNode) =
  durableWrite(path, $data)

proc beginHistory*(root: string): HistorySession =
  if hasHistoryRestore():
    raise newException(IOError, "history restore requires recovery under the package lock")
  assertNoAbandonedHistory(root)
  let canonical = canonicalRoot(root)
  let base = historyDir(root)
  createDir(base)
  setFilePermissions(base, {fpUserRead, fpUserWrite, fpUserExec})
  let path = base / ("pending-" & $getpid() & "-" & $int(epochTime()*1_000_000))
  createDir(path)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})
  result = HistorySession(path: path, root: canonical,
      hadDatabase: fileExists(canonical / kpkgDbPath))
  if result.hadDatabase:
    snapshotDatabase(canonical, path / "before.sqlite")
  let cache = canonical / "etc/ld.so.cache"
  if symlinkExists(cache) or fileExists(cache):
    copyHistoryFile(cache, path / "ld.so.cache")
  if result.hadDatabase: syncPath(path / "before.sqlite")
  if fileExists(path / "ld.so.cache") and not symlinkExists(path / "ld.so.cache"):
    syncPath(path / "ld.so.cache")
  writeAtomic(path / "pending.json", %* {"version": 3, "members": [], "root": canonical,
    "owner": historyOwner(), "hadDatabase": result.hadDatabase,
    "cacheExists": fileExists(path / "ld.so.cache") or symlinkExists(path / "ld.so.cache"),
    "reason": ""})

proc cancelHistory*(session: HistorySession) =
  if session != nil and dirExists(session.path):
    let pending = parseJson(readFile(session.path / "pending.json"))
    if pending.getOrDefault("reason").getStr().len > 0:
      raise newException(IOError, "cannot cancel history with external effects: " & pending["reason"].getStr())
    if not pending.hasKey("members") or pending["members"].kind != JArray or pending["members"].len > 0:
      raise newException(IOError, "cannot cancel history with reserved members; run kpkg history recover: " & session.path)
    for journal in walkFiles(kpkgJournalDir / "*.journal"):
      let tx = loadTransaction(journal)
      if tx.historyPath == session.path:
        raise newException(IOError, "cannot cancel mutated history; run kpkg history recover: " & session.path)
    removeDir(session.path)
    syncPath(parentDir(session.path))

proc fileState(path: string): string =
  var st: Stat
  if lstat(path.cstring, st) != 0: return "absent"
  let metadata = ":" & $st.st_mode & ":" & $st.st_uid & ":" & $st.st_gid
  if symlinkExists(path): return "link:" & expandSymlink(path) & metadata
  if fileExists(path): return "file:" & getSum(path) & metadata
  if dirExists(path): return "directory" & metadata
  "unsupported" & metadata

proc historyAction*(path: string, data: JsonNode): string =
  ## Older entries lack an action field; derive it from their saved snapshots.
  if data.hasKey("action"): return data["action"].getStr()
  type Version = tuple[version, release, epoch: string]
  var before, after: Table[string, Version]
  try:
    if data["hadDatabase"].getBool():
      for pkg in snapshotPackageVersions(path / "before.sqlite"):
        before[pkg.name] = (pkg.version, pkg.release, pkg.epoch)
    if data["afterDatabase"].getBool():
      for pkg in snapshotPackageVersions(path / "after.sqlite"):
        after[pkg.name] = (pkg.version, pkg.release, pkg.epoch)
    var actions: seq[string]
    var names: seq[string]
    for pkg in data["packages"]: names.add(pkg.getStr())
    for name in before.keys:
      if not after.hasKey(name) and name notin names: names.add(name)
    for name in after.keys:
      if not before.hasKey(name) and name notin names: names.add(name)
    for name in names:
      let action = if not before.hasKey(name) and after.hasKey(name): "install"
        elif before.hasKey(name) and not after.hasKey(name): "remove"
        elif not before.hasKey(name): "unknown"
        elif before[name] == after[name]: "reinstall"
        else:
          let old = before[name]
          let current = after[name]
          let direction = compareVersions(current.version & "-" & current.release & "-" & current.epoch,
              old.version & "-" & old.release & "-" & old.epoch)
          if direction > 0: "upgrade"
          elif direction < 0: "downgrade"
          else: "change"
      if action notin actions: actions.add(action)
    result = if actions.len == 1: actions[0] elif actions.len > 1: "mixed" else: "unknown"
  except CatchableError:
    result = "unknown"

proc finishHistory*(session: HistorySession, transactions: seq[Transaction],
                    reason = "") =
  if transactions.len == 0:
    session.cancelHistory()
    return
  let cache = session.root / "etc/ld.so.cache"
  let cacheBackup = session.path / "ld.so.cache"
  if fileExists(cacheBackup) or symlinkExists(cacheBackup):
    transactions[0].recordFileReplaced(cache, cacheBackup)
  elif fileExists(cache) or symlinkExists(cache):
    transactions[0].recordFileCreated(cache)
  var ids: seq[string]
  var packages: seq[string]
  var paths = newJObject()
  var owners = initTable[string, string]()
  let pendingData = parseJson(readFile(session.path / "pending.json"))
  var refusal = pendingData.getOrDefault("reason").getStr()
  if reason.len > 0: refusal = reason
  for tx in transactions:
    ids.add(tx.id)
    packages.add(tx.packageName)
    for op in tx.operations:
      if owners.hasKey(op.path) and owners[op.path] != tx.id and
          op.kind notin {opDirCreated, opDirDeleted}:
        refusal = "parallel batch modified shared paths; file ordering cannot be reconstructed"
      owners[op.path] = tx.id
      if not symlinkExists(op.path) and (fileExists(op.path) or dirExists(op.path)):
        syncPath(op.path)
      if dirExists(parentDir(op.path)): syncAncestors(parentDir(op.path))
      paths[normalizedPath(absolutePath(op.path))] = %fileState(op.path)
      if op.kind == opDirCreated and dirExists(op.path):
        for childPath in walkDirRec(op.path, yieldFilter = {pcFile, pcDir, pcLinkToFile, pcLinkToDir}):
          paths[normalizedPath(absolutePath(childPath))] = %fileState(childPath)
      var ancestor = parentDir(normalizedPath(absolutePath(op.path)))
      while ancestor.len > 0 and ancestor != "/":
        paths[ancestor] = %fileState(ancestor)
        let next = parentDir(ancestor)
        if next == ancestor: break
        ancestor = next
  let fingerprint = databaseFingerprint(session.root)
  closeDb()
  let db = session.root / kpkgDbPath
  if fileExists(db): copyFile(db, session.path / "after.sqlite")
  let data = %* {"id": ids[^1], "ids": ids, "packages": packages,
    "root": session.root, "state": "committed", "reason": refusal,
    "timestamp": epochTime(), "hadDatabase": session.hadDatabase,
    "afterDatabase": fileExists(db), "fingerprint": fingerprint, "paths": paths}
  data["action"] = %historyAction(session.path, data)
  var expectedIds: seq[string]
  for member in pendingData["members"]:
    if member["kind"].getStr() == "journal": expectedIds.add(member["id"].getStr())
  var suppliedIds = ids
  expectedIds.sort()
  suppliedIds.sort()
  if suppliedIds != expectedIds:
    raise newException(IOError, "history finalization does not include the exact reserved journal set")
  for tx in transactions:
    if tx.historyPath != session.path or canonicalRoot(tx.root) != session.root:
      raise newException(IOError, "history finalization transaction identity mismatch")
  # Commit journals before publishing the history entry. A crash before this
  # boundary leaves the pending session recoverable, including mixed states.
  for tx in transactions: tx.commit()
  if fileExists(session.path / "after.sqlite"): syncPath(session.path / "after.sqlite")
  data["members"] = pendingData["members"]
  writeAtomic(session.path / "entry.json", data)
  for member in pendingData["members"]:
    if member["kind"].getStr() == "batch":
      let marker = kpkgJournalDir / ("batch-" & member["id"].getStr() & ".batch")
      if fileExists(marker):
        removeFile(marker)
        syncPath(kpkgJournalDir)
  removeFile(session.path / "pending.json")
  syncPath(session.path)

proc listHistory*(root = "/"): seq[HistoryEntry] =
  let base = historyDir(root)
  if not dirExists(base): return
  for kind, path in walkDir(base):
    if kind != pcDir or not fileExists(path / "entry.json"): continue
    let data = parseJson(readFile(path / "entry.json"))
    var entry = HistoryEntry(id: data["id"].getStr(), state: data["state"].getStr(),
      rollbackReason: data["reason"].getStr(), timestamp: data["timestamp"].getFloat(), path: path)
    entry.action = historyAction(path, data)
    for pkg in data["packages"]: entry.packages.add(pkg.getStr())
    result.add(entry)
  result.sort(proc(a,b: HistoryEntry): int = cmp(a.timestamp,b.timestamp))
  if hasHistoryRestore():
    for entry in result.mitems:
      entry.state = "recovery-required"
      entry.rollbackReason = "unfinished history restore; retry a mutation to recover under the package lock"


proc restoreEntries(id, root: string, inclusive: bool) =
  if hasHistoryRestore():
    raise newException(IOError, "history restore requires recovery under the package lock")
  let entries = listHistory(root)
  var target = -1
  for i, entry in entries:
    let data = parseJson(readFile(entry.path / "entry.json"))
    for member in data["ids"]:
      if member.getStr() == id:
        if id != entry.id:
          raise newException(IOError, "ID is inside an atomic batch; use boundary ID " & entry.id)
        target = i
  if target < 0: raise newException(IOError, "unknown history ID: " & id)
  if entries[target].state != "committed":
    raise newException(IOError, "target is no longer on the active history chain")
  for kind, path in walkDir(historyDir(root)):
    if kind == pcDir and fileExists(path / "pending.json"):
      raise newException(IOError, "incomplete history operation requires manual recovery: " & path)
  for tx in getActiveTransactions():
    if canonicalRoot(tx.root) == canonicalRoot(root):
      raise newException(IOError, "active package transaction requires recovery first")
  # Preflight every entry before changing anything.
  var selected: seq[int]
  for i in countdown(entries.high, target + (if inclusive: 0 else: 1)):
    if entries[i].state != "committed": continue
    if entries[i].rollbackReason.len > 0:
      raise newException(IOError, entries[i].rollbackReason)
    let data = parseJson(readFile(entries[i].path / "entry.json"))
    if data["hadDatabase"].getBool():
      validateDatabaseSnapshot(entries[i].path / "before.sqlite")
    for member in data["ids"]:
      let tx = loadTransaction(kpkgJournalDir / (member.getStr() & ".journal"))
      if tx.state != tsCommitted:
        raise newException(IOError, "history transaction is incomplete or recovered: " & tx.id)
      if canonicalRoot(tx.root) != canonicalRoot(root):
        raise newException(IOError, "history root mismatch")
      for op in tx.operations:
        if op.kind in {opFileDeleted, opFileReplaced}:
          var st: Stat
          if lstat(op.backupPath.cstring, st) != 0 or
              (not S_ISREG(st.st_mode) and not S_ISLNK(st.st_mode)):
            raise newException(IOError, "missing or unsupported file backup: " & op.backupPath)
    selected.add(i)
  if selected.len == 0: return
  closeDb()
  let db = canonicalRoot(root) / kpkgDbPath
  # Validate current metadata and touched paths against newest committed state.
  var expected = initTable[string,string]()
  for i in selected:
    let data = parseJson(readFile(entries[i].path / "entry.json"))
    for path, value in data["paths"]:
      if not expected.hasKey(path): expected[path] = value.getStr()
  for path, value in expected:
    if fileState(path) != value:
      raise newException(IOError, "file changed since installation: " & path)
  for i in selected:
    let data = parseJson(readFile(entries[i].path / "entry.json"))
    for member in data["ids"]:
      let tx = loadTransaction(kpkgJournalDir / (member.getStr() & ".journal"))
      for op in tx.operations:
        if op.kind == opDirCreated and not tx.restoresDirectory(op.path) and
            dirExists(op.path) and not symlinkExists(op.path):
          for child in walkDirRec(op.path, yieldFilter = {pcFile, pcDir, pcLinkToFile, pcLinkToDir}):
            if not expected.hasKey(normalizedPath(absolutePath(child))):
              raise newException(IOError, "untracked file in history directory: " & child)
  let latest = parseJson(readFile(entries[selected[0]].path / "entry.json"))
  if not fileExists(db) or databaseFingerprint(canonicalRoot(root)) != latest["fingerprint"].getStr():
    closeDb()
    raise newException(IOError, "package database changed outside recorded history")
  closeDb()
  # Publish one durable intent before any mutation. Snapshots stay retained.
  # Each step is idempotent, and the cursor prevents replay across entries.
  var steps = newJArray()
  for i in selected:
    let data = parseJson(readFile(entries[i].path / "entry.json"))
    var txs: seq[Transaction]
    for member in data["ids"]:
      txs.add(loadTransaction(kpkgJournalDir / (member.getStr() & ".journal")))
    for j in countdown(txs.high, 0):
      let tx = txs[j]
      for k in countdown(tx.operations.high, 0):
        let op = tx.operations[k]
        if op.kind == opDirCreated and tx.restoresDirectory(op.path): continue
        if op.kind in {opFileDeleted, opFileReplaced}:
          if not symlinkExists(op.backupPath): syncPath(op.backupPath)
          syncAncestors(parentDir(op.backupPath))
        steps.add(%* {"type": "file", "operation": {
          "kind": $op.kind, "path": op.path, "backupPath": op.backupPath,
          "stagingPath": newRestoreStaging(op.path),
          "timestamp": op.timestamp, "mode": op.mode, "uid": op.uid, "gid": op.gid}})
  # Only the oldest selected database snapshot is needed.
  let oldest = entries[selected[^1]]
  let oldestData = parseJson(readFile(oldest.path / "entry.json"))
  let source = if oldestData["hadDatabase"].getBool(): oldest.path / "before.sqlite" else: ""
  if source.len > 0:
    syncPath(source)
    syncAncestors(oldest.path)
  steps.add(%* {"type": "database", "source": source, "path": db,
    "stagingPath": newRestoreStaging(db)})
  for i in selected:
    var data = parseJson(readFile(entries[i].path / "entry.json"))
    for member in data["ids"]:
      let journal = kpkgJournalDir / (member.getStr() & ".journal")
      let original = readFile(journal)
      var contents: string
      let first = parseJson(original.splitLines()[0])
      if first.hasKey("operations"):
        first["state"] = %($tsRolledBack)
        contents = $first
      else:
        contents = original & "\n" & $(%* {"record": "state", "state": $tsRolledBack,
            "timestamp": epochTime()}) & "\n"
      steps.add(%* {"type": "write", "path": journal, "contents": contents})
    data["state"] = %"undone"
    steps.add(%* {"type": "write", "path": entries[i].path / "entry.json", "contents": $data})
  let marker = kpkgJournalDir / (entries[selected[0]].id & ".restore")
  let plan = %* {"version": 1, "root": canonicalRoot(root), "cursor": 0, "steps": steps}
  validateHistoryRestorePlan(marker, plan)
  durableWrite(marker, $plan)
  replayHistoryRestore(marker)

proc rollbackHistory*(id: string, root = "/") =
  ## Revert newer entries, retaining the state AFTER the named batch.
  restoreEntries(id, root, false)

proc undoHistory*(id: string, root = "/") =
  ## Revert the named batch and every newer entry, latest first.
  restoreEntries(id, root, true)

proc cleanHistory*(root = "/", olderThan = 30): int =
  ## Delete only an oldest contiguous prefix, never a hole in the history chain.
  if hasHistoryRestore():
    raise newException(IOError, "history restore requires recovery before cleanup")
  if olderThan < 0:
    raise newException(ValueError, "older-than must be nonnegative")
  let base = historyDir(root)
  if not dirExists(base): return
  for kind, path in walkDir(base):
    if kind == pcDir and fileExists(path / "pending.json"):
      raise newException(IOError, "incomplete history operation requires recovery first: " & path)
  for tx in getActiveTransactions():
    if canonicalRoot(tx.root) == canonicalRoot(root):
      raise newException(IOError, "active transaction requires recovery first")
  let cutoff = epochTime() - float(olderThan) * 86400.0
  var selected: seq[HistoryEntry]
  for entry in listHistory(root):
    if entry.timestamp >= cutoff: break
    if entry.state notin ["committed", "undone"]:
      raise newException(IOError, "cannot clean incomplete history: " & entry.id)
    selected.add(entry)
  # Validate all identifiers and journals before deleting anything.
  var ids: seq[string]
  for entry in selected:
    let data = parseJson(readFile(entry.path / "entry.json"))
    for member in data["ids"]:
      let id = member.getStr()
      if id.len == 0 or id in [".", ".."] or '/' in id or '\\' in id:
        raise newException(IOError, "invalid history transaction ID")
      let journal = kpkgJournalDir / (id & ".journal")
      if fileExists(journal):
        let tx = loadTransaction(journal)
        if tx.state == tsActive or canonicalRoot(tx.root) != canonicalRoot(root):
          raise newException(IOError, "cannot clean active or mismatched journal: " & id)
      ids.add(id)
  # Remove oldest metadata first: an interrupted cleanup cannot leave a hole
  # between retained entries. Leftover backups are harmless and reclaimable.
  for entry in selected:
    removeDir(entry.path)
    inc result
  for id in ids:
    let backup = kpkgBackupDir / id
    if dirExists(backup): removeDir(backup)
    for suffix in [".journal", ".journal.reason"]:
      let path = kpkgJournalDir / (id & suffix)
      if fileExists(path): removeFile(path)

proc pendingPaths(root: string): seq[string] =
  let base = historyDir(root)
  if not dirExists(base): return
  for kind, path in walkDir(base):
    if kind in {pcDir, pcLinkToDir} and
        (fileExists(path / "pending.json") or symlinkExists(path / "pending.json")):
      result.add(path)
  result.sort()

proc inspectPendingHistory*(root = "/"): seq[string] =
  ## Read-only diagnostics; never acquire the mutation lock or replay a plan.
  for path in pendingPaths(root):
    try:
      let data = parseJson(readFile(path / "pending.json"))
      var state = "unvalidated pending operation; run recover for locked validation"
      if data.getOrDefault("version").getInt() != 3:
        state = "manual recovery required: legacy marker lacks durable transaction linkage"
      elif data.getOrDefault("reason").getStr().len > 0:
        state = "manual recovery required: " & data["reason"].getStr()
      result.add(path & ": " & state)
      if data.getOrDefault("version").getInt() == 3:
        result.add("  Phase: " & (if fileExists(path / "entry.json"): "finalization pending" else: "interrupted operation"))
        if not data.hasKey("members") or data["members"].kind != JArray:
          result.add("  Missing or invalid durable member inventory; manual recovery required")
        else:
          for member in data["members"]:
            let id = member["id"].getStr()
            let kind = member["kind"].getStr()
            result.add("  Member: " & kind & " " & id)
            if id.len > 0 and '/' notin id and '\\' notin id:
              let evidence = kpkgJournalDir / (if kind == "batch": "batch-" & id & ".batch" else: id & ".journal")
              if not fileExists(evidence): result.add("  Missing member evidence: " & evidence)
        if data.getOrDefault("hadDatabase").getBool() and not fileExists(path / "before.sqlite"):
          result.add("  Missing database snapshot: " & path / "before.sqlite")
        if data.getOrDefault("cacheExists").getBool() and
            not fileExists(path / "ld.so.cache") and not symlinkExists(path / "ld.so.cache"):
          result.add("  Missing cache snapshot: " & path / "ld.so.cache")
    except CatchableError as e:
      result.add(path & ": manual recovery required: invalid marker: " & e.msg)

proc recoverPendingHistory*(root = "/"): int =
  ## Explicit recovery restores package-managed state, not arbitrary hook effects.
  ## Validate the complete session before publishing an idempotent restore plan.
  if not ownsMutationLock():
    raise newException(IOError, "history recovery requires the package mutation lock")
  recoverHistoryRestores()
  let canonical = canonicalRoot(root)
  let pending = pendingPaths(canonical)
  if pending.len > 1:
    raise newException(IOError, "multiple pending history sessions; ordering is unproven; manual recovery required")
  for path in pending:
    let data = parseJson(readFile(path / "pending.json"))
    if symlinkExists(path) or symlinkExists(path / "pending.json") or
        data.getOrDefault("version").getInt() != 3:
      raise newException(IOError, "legacy or unsupported pending history lacks durable transaction linkage; manual recovery required: " & path)
    if data["root"].getStr() != canonical or not data.hasKey("hadDatabase") or
        not data.hasKey("cacheExists"):
      raise newException(IOError, "invalid pending history metadata: " & path)
    if data["owner"] == historyOwner():
      raise newException(IOError, "cannot recover a live history session: " & path)
    if not data.hasKey("members") or data["members"].kind != JArray:
      raise newException(IOError, "missing durable history member inventory: " & path)
    var memberIds: seq[string]
    var batchIds: seq[string]
    for member in data["members"]:
      let id = member["id"].getStr()
      if id.len == 0 or id in [".", ".."] or '/' in id or '\\' in id:
        raise newException(IOError, "invalid history member ID")
      case member["kind"].getStr()
      of "journal":
        if id in memberIds: raise newException(IOError, "duplicate history journal member")
        memberIds.add(id)
        let journal = kpkgJournalDir / (id & ".journal")
        let tx = loadTransaction(journal)
        if tx.historyPath != path or canonicalRoot(tx.root) != canonical:
          raise newException(IOError, "history member linkage mismatch: " & journal)
      of "batch":
        if id in batchIds: raise newException(IOError, "duplicate history batch member")
        batchIds.add(id)
        let marker = kpkgJournalDir / ("batch-" & id & ".batch")
        if not fileExists(marker):
          if fileExists(path / "entry.json"):
            let entry = parseJson(readFile(path / "entry.json"))
            if entry.getOrDefault("members") == data["members"]: continue
          raise newException(IOError, "missing history batch member: " & marker)
        let batch = parseJson(readFile(marker))
        if batch["id"].getStr() != id or batch["version"].getStr() != "2" or
            batch["historyPath"].getStr() != path or canonicalRoot(batch["root"].getStr()) != canonical:
          raise newException(IOError, "history batch linkage mismatch: " & marker)
      else: raise newException(IOError, "unsupported history member kind")
    var txs: seq[Transaction]
    for journal in walkFiles(kpkgJournalDir / "*.journal"):
      let tx = loadTransaction(journal)
      if tx.historyPath != path:
        if canonicalRoot(tx.root) == canonical and tx.state == tsActive:
          raise newException(IOError, "unlinked active journal; ownership unproven; manual recovery required: " & journal)
        continue
      if canonicalRoot(tx.root) != canonical or tx.id notin memberIds:
        raise newException(IOError, "linked transaction root or inventory mismatch: " & journal)
      txs.add(tx)
    for marker in walkFiles(kpkgJournalDir / "batch-*.batch"):
      let batch = parseJson(readFile(marker))
      if batch.getOrDefault("historyPath").getStr() == path and
          (canonicalRoot(batch["root"].getStr()) != canonical or batch["id"].getStr() notin batchIds):
        raise newException(IOError, "linked batch root or inventory mismatch: " & marker)
      if canonicalRoot(batch["root"].getStr()) == canonical and
          batch.getOrDefault("historyPath").getStr() != path:
        raise newException(IOError, "unlinked batch journal; ownership unproven; manual recovery required: " & marker)
    txs.sort(proc(a,b: Transaction): int = cmp(a.id,b.id))
    var steps = newJArray()
    # An entry is published only after every journal was durably committed.
    # A remaining marker here means finalization, not an abandoned mutation.
    if fileExists(path / "entry.json"):
      let entry = parseJson(readFile(path / "entry.json"))
      if entry["root"].getStr() != canonical or entry["state"].getStr() != "committed" or
          entry.getOrDefault("members") != data["members"] or entry["ids"].len != txs.len:
        raise newException(IOError, "inconsistent finalized pending history: " & path)
      for tx in txs:
        var found = false
        for id in entry["ids"]:
          if id.getStr() == tx.id: found = true
        if not found or tx.state != tsCommitted:
          raise newException(IOError, "finalized history journal mismatch: " & tx.id)
    else:
      if data.getOrDefault("reason").getStr().len > 0:
        raise newException(IOError, "manual recovery required: " & data["reason"].getStr())
      var owners = initTable[string, string]()
      for tx in txs:
        for op in tx.operations:
          let target = canonicalRoot(op.path)
          if target != canonical and not target.startsWith(canonical.strip(leading = false, trailing = true, chars = {'/'}) & "/"):
            raise newException(IOError, "transaction path outside recovery root: " & op.path)
          if owners.hasKey(target) and owners[target] != tx.id:
            raise newException(IOError, "parallel batch modified shared paths; ordering is unproven; manual recovery required: " & target)
          owners[target] = tx.id
          var ancestor = parentDir(target)
          while ancestor.len > 0:
            if symlinkExists(ancestor):
              raise newException(IOError, "symlink ancestor blocks safe recovery: " & ancestor)
            let parent = parentDir(ancestor)
            if parent == ancestor: break
            ancestor = parent
          if op.kind in {opFileCreated, opFileReplaced, opFileDeleted, opSymlinkCreated} and
              dirExists(target) and not symlinkExists(target):
            raise newException(IOError, "file path replaced by directory: " & target)
          if op.kind in {opFileDeleted, opFileReplaced}:
            var st: Stat
            if lstat(op.backupPath.cstring, st) != 0 or
                (not S_ISREG(st.st_mode) and not S_ISLNK(st.st_mode)):
              raise newException(IOError, "missing or unsupported recovery backup: " & op.backupPath)
      for tx in txs:
        for op in tx.operations:
          if op.kind == opDirCreated and not tx.restoresDirectory(op.path) and
              dirExists(op.path) and not symlinkExists(op.path):
            for child in walkDirRec(op.path, yieldFilter = {pcFile, pcDir, pcLinkToFile, pcLinkToDir}):
              if not owners.hasKey(canonicalRoot(child)):
                raise newException(IOError, "untracked file in recovery directory: " & child)
      for i in countdown(txs.high, 0):
        let tx = txs[i]
        for j in countdown(tx.operations.high, 0):
          let op = tx.operations[j]
          if op.kind == opDirCreated and tx.restoresDirectory(op.path): continue
          if op.kind in {opFileDeleted, opFileReplaced}:
            if not symlinkExists(op.backupPath): syncPath(op.backupPath)
            syncAncestors(parentDir(op.backupPath))
          steps.add(%* {"type": "file", "operation": {
            "kind": $op.kind, "path": op.path, "backupPath": op.backupPath,
            "stagingPath": newRestoreStaging(op.path), "timestamp": op.timestamp,
            "mode": op.mode, "uid": op.uid, "gid": op.gid}})
      let cache = canonical / "etc/ld.so.cache"
      let cacheBackup = path / "ld.so.cache"
      for target in [cache, canonical / kpkgDbPath]:
        var ancestor = parentDir(target)
        while ancestor.len > 0:
          if symlinkExists(ancestor):
            raise newException(IOError, "symlink ancestor blocks safe recovery: " & ancestor)
          let parent = parentDir(ancestor)
          if parent == ancestor: break
          ancestor = parent
      if data["cacheExists"].getBool():
        var st: Stat
        if lstat(cacheBackup.cstring, st) != 0 or
            (not S_ISREG(st.st_mode) and not S_ISLNK(st.st_mode)):
          raise newException(IOError, "missing cache snapshot: " & cacheBackup)
      steps.add(%* {"type": "file", "operation": {
        "kind": (if data["cacheExists"].getBool(): $opFileReplaced else: $opFileCreated),
        "path": cache, "backupPath": cacheBackup, "stagingPath": newRestoreStaging(cache),
        "timestamp": 0.0, "mode": 0, "uid": 0, "gid": 0}})
      let source = if data["hadDatabase"].getBool(): path / "before.sqlite" else: ""
      if source.len > 0:
        validateDatabaseSnapshot(source)
        syncPath(source)
      let db = canonical / kpkgDbPath
      steps.add(%* {"type": "database", "source": source, "path": db,
        "stagingPath": newRestoreStaging(db)})
      for tx in txs:
        let contents = readFile(tx.journalPath) & "\n" &
          $(%* {"record": "state", "state": $tsRolledBack, "timestamp": epochTime()}) & "\n"
        steps.add(%* {"type": "write", "path": tx.journalPath, "contents": contents})
      steps.add(%* {"type": "write", "path": path / "recovered.json",
        "contents": $(%* {"version": 2, "root": canonical, "state": "recovered", "timestamp": epochTime()})})
    # Retire only batch markers carrying the same exact durable identity.
    for marker in walkFiles(kpkgJournalDir / "batch-*.batch"):
      let batch = parseJson(readFile(marker))
      if batch.getOrDefault("historyPath").getStr() == path:
        steps.add(%* {"type": "remove", "path": marker})
    steps.add(%* {"type": "remove", "path": path / "pending.json"})
    createDir(kpkgJournalDir)
    let marker = kpkgJournalDir / (lastPathPart(path) & ".restore")
    let plan = %* {"version": 1, "root": canonical, "cursor": 0, "steps": steps,
      "session": path, "sessionMetadata": data}
    validateHistoryRestorePlan(marker, plan)
    durableWrite(marker, $plan)
    replayHistoryRestore(marker)
    inc result
