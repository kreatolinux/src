## Persistent per-core unit-name indexes (specification section 14.3).
##
## The directory on disk is deliberately only a cache.  Callers tell `load`
## which cores are enabled; files belonging to every other core are left in
## place, but are not admitted to the in-memory set.
import std/[algorithm, os, sets, strutils, tables]
import jumpstartcore/names

type
  NameIndexError* = object of CatchableError
    ## Invalid core/name data or an invalid on-disk index.
    core*: string

  NameIndex* = object
    ## A present, empty index is distinct from there being no index for a core.
    names*: HashSet[string]

  NameIndexStore* = object
    ## Directory containing one file per core (CorePaths.nameIndexRoot).
    root*: string
    indexes*: Table[string, NameIndex]

var temporarySerial {.threadvar.}: uint

proc fail(core, message: string) {.noreturn.} =
  var error = newException(NameIndexError, message)
  error.core = core
  raise error

proc checkCore(core: string) =
  # Reserved names (notably serviceHandler) are valid index owners.
  if not validCoreName(core, extension = false):
    fail(core, "invalid core name for name index: " & core)

proc checkName(core, name: string) =
  if not validUnitName(name):
    fail(core, "invalid unit name in name index for " & core)

proc initNameIndexStore*(root: string): NameIndexStore =
  if root.len == 0:
    raise newException(ValueError, "name-index root is empty")
  NameIndexStore(root: root, indexes: initTable[string, NameIndex]())

proc nameIndexDir*(store: NameIndexStore): string = store.root

proc nameIndexPath*(store: NameIndexStore; core: string): string =
  checkCore(core)
  store.nameIndexDir / core

proc hasIndex*(store: NameIndexStore; core: string): bool =
  store.indexes.hasKey(core)

proc contains*(store: NameIndexStore; core, name: string): bool =
  ## False means either that no index is known or that the name is absent.
  store.indexes.hasKey(core) and name in store.indexes[core].names

proc indexedNames*(store: NameIndexStore; core: string): seq[string] =
  ## Return a stable representation useful for snapshots and diagnostics.
  if not store.indexes.hasKey(core): return
  for name in store.indexes[core].names:
    result.add(name)
  result.sort(system.cmp[string])

proc makeIndex(core: string; names: openArray[string]): NameIndex =
  checkCore(core)
  result.names = initHashSet[string]()
  for name in names:
    checkName(core, name)
    result.names.incl(name)

proc contents(index: NameIndex): string =
  var ordered: seq[string]
  for name in index.names: ordered.add(name)
  ordered.sort(system.cmp[string])
  for name in ordered:
    result.add(name)
    result.add('\n')

proc persist(store: NameIndexStore; core: string; index: NameIndex) =
  let destination = store.nameIndexPath(core)
  createDir(parentDir(destination))

  inc temporarySerial
  let temporary = destination & ".tmp-" & $getCurrentProcessId() & "-" &
    $temporarySerial
  try:
    writeFile(temporary, index.contents)
    # The temporary is in the destination directory, so rename is atomic.
    moveFile(temporary, destination)
  finally:
    if fileExists(temporary): removeFile(temporary)

proc refresh*(store: var NameIndexStore; core: string;
              names: openArray[string]) =
  ## Apply a successful unit.list (including the seed call at publication).
  ## A successful empty list creates a known-empty index.
  let replacement = makeIndex(core, names)
  store.persist(core, replacement)
  store.indexes[core] = replacement

proc recordOwned*(store: var NameIndexStore; core, requested,
                  canonical: string) =
  ## Apply an `owned: true` unit.resolve response.  Both spellings are useful:
  ## the requested spelling protects aliases, while the canonical spelling
  ## protects subsequent requests in the form used for dispatch.
  checkCore(core)
  checkName(core, requested)
  checkName(core, canonical)

  var replacement: NameIndex
  replacement.names = initHashSet[string]()
  if store.indexes.hasKey(core):
    # Copy members rather than sharing HashSet storage: a failed persistence
    # must leave the live in-memory index unchanged.
    for name in store.indexes[core].names:
      replacement.names.incl(name)
  replacement.names.incl(requested)
  replacement.names.incl(canonical)
  store.persist(core, replacement)
  store.indexes[core] = replacement

proc readIndex(path, core: string): NameIndex =
  result.names = initHashSet[string]()
  let data = readFile(path)
  if data.len == 0: return
  if not data.endsWith("\n"):
    fail(core, "name index must end with a newline: " & path)
  for line in data[0 ..< data.high].split('\n'):
    checkName(core, line)
    result.names.incl(line)

proc load*(store: var NameIndexStore; enabledCores: openArray[string]) =
  ## Load only enabled cores.  This replaces the complete in-memory view, so a
  ## core disabled since the previous call is immediately ignored.  Missing
  ## files remain unknown; an existing empty file is a known-empty index.
  var replacement = initTable[string, NameIndex]()
  var seen = initHashSet[string]()
  for core in enabledCores:
    checkCore(core)
    if core in seen: continue
    seen.incl(core)
    let path = store.nameIndexPath(core)
    if fileExists(path):
      replacement[core] = readIndex(path, core)
  store.indexes = move(replacement)

proc loadNameIndexes*(root: string;
                      enabledCores: openArray[string]): NameIndexStore =
  result = initNameIndexStore(root)
  result.load(enabledCores)

proc refreshAfterList*(store: var NameIndexStore; core: string;
                       names: openArray[string]) =
  ## Explicit event-oriented spelling for callers handling unit.list/load.
  store.refresh(core, names)

proc refreshAfterLoad*(store: var NameIndexStore; core: string;
                       names: openArray[string]) =
  store.refresh(core, names)
