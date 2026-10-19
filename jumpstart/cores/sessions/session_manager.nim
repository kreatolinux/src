## Operational edge for the pure §7.6 session model.
##
## Socket credential acquisition, pidfds, account lookup, runtime/cgroup
## setup, process supervision and marker I/O are callbacks.  Production Linux
## adapters can perform those privileged operations without putting them in
## the policy model; tests use memory-backed implementations.
import std/[algorithm, json, sequtils, sets, tables]
import posix
import ../daemon/control, ./sessions
import jumpstartcore/[errors, peercred]

type
  AccountInfo* = object
    uid*: SessionUid
    gid*: uint32
    name*, home*, shell*: string

  AcceptedPeer* = object
    pid*: int
    uid*: SessionUid
    acceptedAt*: MonotonicSeconds
    peerPidfd*: int             ## -1 means SO_PEERPIDFD was unavailable.

  PeerOps* = object
    pidfdOpen*: proc(pid: int): int {.closure.}
    processStart*: proc(pid: int): MonotonicSeconds {.closure.}
    processUid*: proc(pid: int): SessionUid {.closure.}
    closeFd*: proc(fd: int) {.closure.}

  LingerFs* = object
    listNames*: proc(): seq[string] {.closure.}
    createMarker*: proc(name: string) {.closure.}
    removeMarker*: proc(name: string) {.closure.}

  AccountOps* = object
    byName*: proc(name: string): AccountInfo {.closure.}
    byUid*: proc(uid: SessionUid): AccountInfo {.closure.}

  SessionRuntimeOps* = object
    ## The adapter implements §7.6.4/5, including jumpstart --user, identity,
    ## tmpfs, cgroup delegation, readiness and TERM/KILL timeouts.
    start*: proc(account: AccountInfo; reason: StartReason): StartOutcome {.closure.}
    stop*: proc(account: AccountInfo) {.closure.}

  SessionManager* = object
    model*: SessionModel
    accounts*: AccountOps
    peers*: PeerOps
    lingerFs*: LingerFs
    runtime*: SessionRuntimeOps
    names: Table[SessionUid, string]

proc requireAccount(account: AccountInfo; requested: SessionUid): AccountInfo =
  if requested == 0 or account.uid != requested or account.name.len == 0 or
      account.home.len == 0:
    raise newCoreError(ecNotFound, "user account not found")
  account

proc accountFor(manager: SessionManager; uid: SessionUid): AccountInfo =
  if manager.accounts.byUid.isNil:
    raise newCoreError(ecBackend, "UID account lookup is unavailable")
  try: requireAccount(manager.accounts.byUid(uid), uid)
  except CoreError: raise
  except CatchableError: raise newCoreError(ecNotFound, "user account not found: " & $uid)

proc initSessionManager*(accounts: AccountOps; peers: PeerOps;
                         lingerFs: LingerFs; runtime: SessionRuntimeOps): SessionManager =
  result.accounts = accounts
  result.peers = peers
  result.lingerFs = lingerFs
  result.runtime = runtime
  result.names = initTable[SessionUid, string]()
  let accountLookup = accounts
  let runtimeCopy = runtime
  let peerCopy = peers
  result.model = initSessionModel(PlatformOps(
    startUser: proc(uid: SessionUid; reason: StartReason): StartOutcome =
      if accountLookup.byUid.isNil or runtimeCopy.start.isNil: return soFailed
      runtimeCopy.start(requireAccount(accountLookup.byUid(uid), uid), reason),
    stopUser: proc(uid: SessionUid) =
      if not accountLookup.byUid.isNil and not runtimeCopy.stop.isNil:
        runtimeCopy.stop(requireAccount(accountLookup.byUid(uid), uid)),
    releasePeer: proc(fd: int) =
      if not peerCopy.closeFd.isNil: peerCopy.closeFd(fd)))

proc acquirePeer*(manager: SessionManager; accepted: AcceptedPeer): PeerMetadata =
  ## Prefer SO_PEERPIDFD.  Fallback acquisition performs the start-time and
  ## root-UID checks required to close the PID reuse race.
  if accepted.pid <= 0 or accepted.uid != 0:
    raise newCoreError(ecPermission, "session request requires a root peer")
  if accepted.peerPidfd >= 0:
    return PeerMetadata(pid: accepted.pid, pidfd: accepted.peerPidfd,
      peerUid: accepted.uid, source: psPeerPidfd,
      acceptedAt: accepted.acceptedAt)
  if manager.peers.pidfdOpen.isNil or manager.peers.processStart.isNil or
      manager.peers.processUid.isNil:
    raise newCoreError(ecPermission, "safe peer pidfd acquisition is unavailable")
  var fd = -1
  try:
    fd = manager.peers.pidfdOpen(accepted.pid)
    let started = manager.peers.processStart(accepted.pid)
    let uid = manager.peers.processUid(accepted.pid)
    if fd < 0 or started >= accepted.acceptedAt or uid != 0:
      raise newCoreError(ecPermission, "peer PID changed during pidfd acquisition")
    PeerMetadata(pid: accepted.pid, pidfd: fd, peerUid: uid,
      source: psPeerCredFallback, acceptedAt: accepted.acceptedAt,
      processStart: started)
  except:
    if fd >= 0 and not manager.peers.closeFd.isNil: manager.peers.closeFd(fd)
    raise

proc mapResult(value: SessionResult): ControlResponse =
  if value.ok: return okResponse(%* {"action": $value.action})
  let code = case value.code
    of secPermission: ecPermission
    of secInvalidId: ecUsage
    # §18 defines no session code. E_STATE is the enabled-state directory;
    # "operation invalid in the current state" is E_UNIT_STATE (§18 note).
    of secAlreadyOpen, secNotOpen: ecUnitState
    of secPlatform: ecBackend
    of secNone: ecBackend
  errorResponse(code, value.message)

proc handleSession*(manager: var SessionManager; request: SessionRequest;
                    accepted: AcceptedPeer; now: MonotonicSeconds): ControlResponse =
  if request.uid < 0 or uint64(request.uid) > uint64(high(SessionUid)):
    return errorResponse(ecUsage, "session UID is outside uid_t range")
  let uid = SessionUid(request.uid)
  if accepted.uid != 0:
    return errorResponse(ecPermission, "session request requires a root peer")
  if uid == 0: return okResponse()
  case request.action
  of "open":
    var peer: PeerMetadata
    try:
      discard manager.accountFor(uid)
      peer = manager.acquirePeer(accepted)
    except CoreError as e: return errorResponse(e.code, e.msg)
    let response = manager.model.openSession(uid, request.id, peer, now)
    if response.ok: manager.names[uid] = manager.accountFor(uid).name
    mapResult(response)
  of "close": mapResult(manager.model.closeSession(uid, request.id))
  else: errorResponse(ecUsage, "session action must be open or close")

proc loadLinger*(manager: var SessionManager) =
  ## Resolve names every time markers are loaded; stale/renamed accounts are
  ## ignored rather than preserving UID identity from a previous lookup.
  if manager.lingerFs.listNames.isNil: return
  var seen = initHashSet[SessionUid]()
  for name in manager.lingerFs.listNames():
    if name.len == 0 or name == "root" or manager.accounts.byName.isNil: continue
    try:
      let account = manager.accounts.byName(name)
      if account.uid == 0 or account.name != name: continue
      discard manager.model.setLinger(account.uid, true)
      manager.names[account.uid] = account.name
      seen.incl(account.uid)
    except CatchableError: discard
  for uid in manager.model.managedUids:
    if manager.model.snapshot(uid, 0).linger and uid notin seen:
      discard manager.model.setLinger(uid, false)

proc setLingerMarker*(manager: var SessionManager; name: string;
                      enabled: bool): SessionResult =
  if name.len == 0 or name == "root": raise newCoreError(ecUsage, "root cannot linger")
  if manager.accounts.byName.isNil: raise newCoreError(ecBackend, "account lookup unavailable")
  var account: AccountInfo
  try: account = manager.accounts.byName(name)
  except CatchableError: raise newCoreError(ecNotFound, "user not found: " & name)
  if account.uid == 0 or account.name != name:
    raise newCoreError(ecNotFound, "user not found: " & name)
  if enabled:
    if manager.lingerFs.createMarker.isNil: raise newCoreError(ecIo, "linger store unavailable")
    manager.lingerFs.createMarker(name)
  else:
    if manager.lingerFs.removeMarker.isNil: raise newCoreError(ecIo, "linger store unavailable")
    manager.lingerFs.removeMarker(name)
  manager.names[account.uid] = name
  manager.model.setLinger(account.uid, enabled)

proc lingerNames*(manager: SessionManager): seq[string] =
  if not manager.lingerFs.listNames.isNil: result = manager.lingerFs.listNames()
  result.sort(system.cmp[string])
  result = result.deduplicate()

proc usersJson*(manager: SessionManager; now: MonotonicSeconds): JsonNode =
  ## §21.8: one row per user daemon the system daemon manages, with STATE one
  ## of `running`, `starting`, `stopping`, or `failed`. A user with neither
  ## sessions nor linger whose daemon is stopped has no row. A user the daemon
  ## is expected to run for (open sessions or linger) but whose daemon is not
  ## running is `starting` while a start is still due (a lingering user before
  ## the boot start, §7.6 step 6) and `failed` once it exited and will not be
  ## restarted before the next session (§7.6 step 7).
  result = newJArray()
  for item in manager.model.snapshots(now):
    if item.state == udsStopped and item.sessions == 0 and not item.linger: continue
    let name = if manager.names.hasKey(item.uid): manager.names[item.uid]
               else: $item.uid
    let state =
      if item.state != udsStopped: daemonStateName(item.state)
      elif item.restartBlocked: "failed"
      else: "starting"
    result.add(%* {"uid": item.uid, "user": name, "sessions": item.sessions,
      "state": state, "linger": item.linger})

proc handleUsers*(manager: SessionManager; request: UsersRequest;
                  systemMode: bool; now: MonotonicSeconds): ControlResponse =
  if not systemMode: return errorResponse(ecUsage, "users is available only in system mode")
  if request.action != "list": return errorResponse(ecUsage, "unknown users action")
  okResponse(%* {"users": manager.usersJson(now)})


# Production operations ------------------------------------------------------

proc accountFromPasswd(entry: ptr Passwd): AccountInfo =
  if entry.isNil: raise newCoreError(ecNotFound, "user not found")
  AccountInfo(uid: SessionUid(entry.pw_uid), gid: uint32(entry.pw_gid),
    name: $entry.pw_name, home: $entry.pw_dir,
    # passwd(5): an empty shell field means /bin/sh.
    shell: if entry.pw_shell.isNil or entry.pw_shell[0] == '\0': "/bin/sh"
           else: $entry.pw_shell)

proc passwdAccounts*(): AccountOps =
  ## Password-database lookups (getpwnam/getpwuid). Never consults HOME.
  AccountOps(
    byName: proc(name: string): AccountInfo = accountFromPasswd(getpwnam(name.cstring)),
    byUid: proc(uid: SessionUid): AccountInfo = accountFromPasswd(getpwuid(Uid(uid))))

proc procPeerOps*(procRoot = "/proc"): PeerOps =
  ## §7.6 step 3 fallback: pidfd_open, start time (field 22 of
  ## /proc/PID/stat, clock ticks since boot) and the real UID.
  PeerOps(
    pidfdOpen: proc(pid: int): int =
      let fd = pidfdOpen(pid)
      if fd < 0: raise newCoreError(ecPermission, "pidfd_open is unavailable")
      int(fd),
    processStart: proc(pid: int): MonotonicSeconds = processStartTicks(pid, procRoot),
    processUid: proc(pid: int): SessionUid =
      let uid = processRealUid(pid, procRoot)
      if uid < 0 or uid > int64(high(SessionUid)):
        raise newCoreError(ecPermission, "peer UID out of range")
      SessionUid(uid),
    closeFd: proc(fd: int) = discard posix.close(cint(fd)))

proc acceptedPeerFor*(fd: cint): AcceptedPeer =
  ## Call right after accept(2): SO_PEERCRED, SO_PEERPIDFD when the kernel
  ## has it, and the acceptance time in the same unit as /proc start times.
  let cred = peerCredentials(fd)
  if cred.uid < 0 or cred.uid > int64(high(SessionUid)):
    raise newCoreError(ecPermission, "peer UID out of range")
  AcceptedPeer(pid: cred.pid, uid: SessionUid(cred.uid),
               acceptedAt: bootTimeTicks(), peerPidfd: int(peerPidfd(fd)))
