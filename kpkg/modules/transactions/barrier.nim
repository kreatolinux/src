## Incomplete history blocks mutations, except the current process's live batch.
## A per-lease random nonce is shared by workers and rotated at final unlock.
import std/[os, json, sysrand, posix, locks]
var historyOwnerNonce: array[16, byte]
if not urandom(historyOwnerNonce):
  raise newException(IOError, "cannot initialize history ownership")

proc historyOwner*(): JsonNode =
  %* {"pid": int(getpid()), "nonce": $historyOwnerNonce}

proc currentHistoryPath*(root: string): string =
  ## The journal header links to this path before any package mutation.
  let canonical = normalizedPath(absolutePath(if root.len == 0: "/" else: root))
  let base = canonical / "var/lib/kpkg/history"
  if not dirExists(base): return
  for kind, path in walkDir(base):
    if kind notin {pcDir, pcLinkToDir}: continue
    let marker = path / "pending.json"
    if dirExists(marker) or symlinkExists(marker):
      raise newException(IOError, "invalid pending history marker: " & marker)
    if not fileExists(marker): continue
    if kind != pcDir:
      raise newException(IOError, "invalid pending history directory: " & path)
    let data = parseJson(readFile(marker))
    if data.kind != JObject or not data.hasKey("owner") or
        data["owner"] != historyOwner():
      raise newException(IOError, "incomplete history operation requires recovery: " & path)
    if not data.hasKey("root") or data["root"].getStr() != canonical:
      raise newException(IOError, "pending history root mismatch: " & path)
    if result.len > 0:
      raise newException(IOError, "multiple live pending history operations: " & base)
    result = path

proc assertNoAbandonedHistory*(root: string) =
  discard currentHistoryPath(root)

var historyBarrierLock: Lock
initLock(historyBarrierLock)

proc barrierRename(source, destination: cstring): cint {.importc: "rename",
    header: "<stdio.h>".}

proc syncBarrierPath(path: string) =
  let fd = posix.open(path.cstring, O_RDONLY)
  if fd < 0: raiseOSError(osLastError(), "cannot open history barrier " & path)
  defer: discard posix.close(fd)
  if fsync(fd) != 0: raiseOSError(osLastError(),
      "cannot sync history barrier " & path)

proc writePendingMetadata(path: string, data: JsonNode) =
  ## Caller holds historyBarrierLock across the read-modify-publish sequence.
  let marker = path / "pending.json"
  let temporary = marker & ".barrier-partial"
  writeFile(temporary, $data)
  syncBarrierPath(temporary)
  if barrierRename(temporary.cstring, marker.cstring) != 0:
    raiseOSError(osLastError(), "cannot publish history barrier")
  var directory = path
  while true:
    syncBarrierPath(directory)
    let parent = parentDir(directory)
    if parent == directory or parent.len == 0: break
    directory = parent

proc markHistoryBarrier*(root, reason: string) =
  ## Publish the refusal BEFORE hooks or other untracked effects can run.
  if reason.len == 0: return
  acquire(historyBarrierLock)
  defer: release(historyBarrierLock)
  let path = currentHistoryPath(root)
  if path.len == 0:
    raise newException(IOError, "untracked mutation requires a live history session")
  var data = parseJson(readFile(path / "pending.json"))
  if data.hasKey("reason") and data["reason"].getStr().len > 0: return
  data["reason"] = %reason
  writePendingMetadata(path, data)

proc reserveHistoryMember*(root, id, kind: string): string =
  ## Reserve before publishing a journal. A missing reserved journal makes
  ## recovery refuse rather than silently omit a transaction's effects.
  if kind notin ["journal", "batch"] or id.len == 0:
    raise newException(IOError, "invalid history member reservation")
  acquire(historyBarrierLock)
  defer: release(historyBarrierLock)
  result = currentHistoryPath(root)
  if result.len == 0: return
  var data = parseJson(readFile(result / "pending.json"))
  if not data.hasKey("version") or data["version"].getInt() != 3 or
      not data.hasKey("members") or data["members"].kind != JArray:
    raise newException(IOError, "history inventory requires pending version 3")
  for member in data["members"]:
    if member.kind != JObject or not member.hasKey("id") or
        not member.hasKey("kind"):
      raise newException(IOError, "invalid pending history inventory")
    if member["id"].getStr() == id:
      raise newException(IOError, "duplicate pending history member: " & id)
  data["members"].add( %* {"id": id, "kind": kind})
  writePendingMetadata(result, data)

proc releaseHistoryOwnership*() =
  ## Called only when the last package-lock lease exits, after workers join.
  if not urandom(historyOwnerNonce):
    raise newException(IOError, "cannot reset history ownership")
