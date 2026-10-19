## Process-free user-session supervisor model (jumpstart-cores specification §7.6).
##
## This module owns policy only.  Mounting runtime directories, manipulating
## cgroups, pidfds, signals and processes are supplied by PlatformOps.  The
## callbacks may therefore be fakes in tests and the same model can be used on
## non-Linux build hosts.
import std/[algorithm, tables]

type
  SessionUid* = uint32
  SessionId* = string
  MonotonicSeconds* = int64

  PeerSource* = enum
    ## A direct SO_PEERPIDFD does not need the PID-reuse fallback check.
    psPeerPidfd, psPeerCredFallback

  PeerMetadata* = object
    pid*: int
    pidfd*: int
    peerUid*: SessionUid
    source*: PeerSource
    acceptedAt*: MonotonicSeconds
    processStart*: MonotonicSeconds

  UserDaemonState* = enum
    udsStopped, udsStarting, udsRunning, udsStopping, udsFailed

  StartReason* = enum
    srFirstSession, srNewSessionRetry, srLingerBoot, srUnexpectedExit

  StartOutcome* = enum
    soStarted,
    soSocketInUse,             ## A hand-started daemon owns the socket.
    soFailed

  PlatformOps* = object
    ## startUser encapsulates runtime tmpfs/cgroup setup, spawn, and the socket
    ## readiness wait. stopUser encapsulates TERM/KILL, cgroup cleanup and
    ## runtime unmount. releasePeer closes a pidfd owned by this model.
    startUser*: proc(uid: SessionUid; reason: StartReason): StartOutcome {.closure.}
    stopUser*: proc(uid: SessionUid) {.closure.}
    releasePeer*: proc(pidfd: int) {.closure.}

  SessionErrorCode* = enum
    secNone, secPermission, secInvalidId, secAlreadyOpen, secNotOpen,
    secPlatform

  SessionAction* = enum
    saNone, saIgnoredRoot, saOpened, saClosed, saStarted, saStartFailed,
    saSocketInUse, saStopped, saRestarted, saRestartBudgetExceeded

  SessionResult* = object
    ok*: bool
    code*: SessionErrorCode
    action*: SessionAction
    message*: string

  SessionRecord* = object
    id*: SessionId
    uid*: SessionUid
    peer*: PeerMetadata

  UserSnapshot* = object
    uid*: SessionUid
    sessions*: int
    linger*: bool
    state*: UserDaemonState
    restartAttempts*: int
    restartBlocked*: bool

  UserEntry = object
    sessions: Table[SessionId, SessionRecord]
    linger: bool
    state: UserDaemonState
    restartTimes: seq[MonotonicSeconds]
    restartBlocked: bool

  SessionModel* = object
    users: Table[SessionUid, UserEntry]
    ops: PlatformOps

const
  RestartLimit* = 5
  RestartWindowSeconds* = 60'i64

proc success(action: SessionAction): SessionResult =
  SessionResult(ok: true, code: secNone, action: action)

proc failure(code: SessionErrorCode; message: string): SessionResult =
  SessionResult(ok: false, code: code, action: saNone, message: message)

proc initSessionModel*(ops: PlatformOps = PlatformOps()): SessionModel =
  result.users = initTable[SessionUid, UserEntry]()
  result.ops = ops

proc validPeer(peer: PeerMetadata): bool =
  if peer.pid <= 0 or peer.pidfd < 0 or peer.peerUid != 0: return false
  peer.source == psPeerPidfd or peer.processStart < peer.acceptedAt

proc releasePeer(model: SessionModel; peer: PeerMetadata) =
  if not model.ops.releasePeer.isNil and peer.pidfd >= 0:
    model.ops.releasePeer(peer.pidfd)

proc ensureUser(model: var SessionModel; uid: SessionUid) =
  if not model.users.hasKey(uid):
    model.users[uid] = UserEntry(
      sessions: initTable[SessionId, SessionRecord](),
      state: udsStopped)

proc pruneRestarts(entry: var UserEntry; now: MonotonicSeconds) =
  var first = 0
  while first < entry.restartTimes.len and
      now - entry.restartTimes[first] >= RestartWindowSeconds:
    inc first
  if first > 0: entry.restartTimes = entry.restartTimes[first .. ^1]

proc invokeStart(model: var SessionModel; uid: SessionUid;
                 reason: StartReason): StartOutcome =
  model.users[uid].state = udsStarting
  if model.ops.startUser.isNil:
    result = soStarted
  else:
    result = model.ops.startUser(uid, reason)
  case result
  of soStarted: model.users[uid].state = udsRunning
  of soSocketInUse: model.users[uid].state = udsStopped
  of soFailed: model.users[uid].state = udsFailed

proc stopUser(model: var SessionModel; uid: SessionUid): SessionResult =
  model.users[uid].state = udsStopping
  if not model.ops.stopUser.isNil: model.ops.stopUser(uid)
  model.users[uid].state = udsStopped
  model.users[uid].restartBlocked = false
  model.users[uid].restartTimes.setLen(0)
  success(saStopped)

proc openSession*(model: var SessionModel; uid: SessionUid; id: SessionId;
                  peer: PeerMetadata; now: MonotonicSeconds): SessionResult =
  ## Takes ownership of peer.pidfd, including on rejected/ignored requests.
  if uid == 0:
    model.releasePeer(peer)
    return success(saIgnoredRoot)
  if id.len == 0:
    model.releasePeer(peer)
    return failure(secInvalidId, "session id is empty")
  if not validPeer(peer):
    model.releasePeer(peer)
    return failure(secPermission, "untrusted peer or reused PID")
  model.ensureUser(uid)
  if model.users[uid].sessions.hasKey(id):
    model.releasePeer(peer)
    return failure(secAlreadyOpen, "session id is already open for UID")

  let wasEmpty = model.users[uid].sessions.len == 0
  model.users[uid].sessions[id] = SessionRecord(id: id, uid: uid, peer: peer)
  # A blocked daemon gets a fresh budget at the explicit retry trigger in
  # §7.6.7. Merely opening an additional healthy session does not erase a
  # currently active crash window.
  if model.users[uid].restartBlocked:
    model.users[uid].restartBlocked = false
    model.users[uid].restartTimes.setLen(0)
  if model.users[uid].state in {udsStopped, udsFailed}:
    let outcome = model.invokeStart(uid,
      if wasEmpty: srFirstSession else: srNewSessionRetry)
    case outcome
    of soStarted: return success(saStarted)
    of soSocketInUse:
      return SessionResult(ok: false, code: secPlatform,
        action: saSocketInUse, message: "user socket is already in use")
    of soFailed:
      return SessionResult(ok: false, code: secPlatform,
        action: saStartFailed, message: "user daemon failed to start")
  success(saOpened)

proc closeSession*(model: var SessionModel; uid: SessionUid;
                   id: SessionId): SessionResult =
  if uid == 0: return success(saIgnoredRoot)
  if not model.users.hasKey(uid) or not model.users[uid].sessions.hasKey(id):
    return failure(secNotOpen, "session id is not open for UID")
  let peer = model.users[uid].sessions[id].peer
  model.users[uid].sessions.del(id)
  model.releasePeer(peer)
  # The platform stop is idempotent and also releases the runtime mount and
  # cgroup of a daemon that already exited (e.g. after its restart budget was
  # used up), so it runs on every last close of a non-lingering user.
  if model.users[uid].sessions.len == 0 and not model.users[uid].linger:
    return model.stopUser(uid)
  success(saClosed)

proc peerExited*(model: var SessionModel; pidfd: int): seq[SessionResult] =
  ## pidfds uniquely identify processes, so one readiness notification can
  ## close several sessions opened by the same login process.
  var found: seq[(SessionUid, SessionId)]
  for uid, entry in model.users:
    for id, session in entry.sessions:
      if session.peer.pidfd == pidfd: found.add((uid, id))
  for item in found: result.add(model.closeSession(item[0], item[1]))

proc setLinger*(model: var SessionModel; uid: SessionUid; enabled: bool): SessionResult =
  if uid == 0: return success(saIgnoredRoot)
  model.ensureUser(uid)
  let wasLingering = model.users[uid].linger
  model.users[uid].linger = enabled
  if not enabled and wasLingering and model.users[uid].sessions.len == 0:
    # §21.8: disabling linger never stops a daemon that still has sessions.
    # Without sessions the platform stop also releases leftover resources.
    return model.stopUser(uid)
  success(saNone)

proc startLingeringUsers*(model: var SessionModel): seq[SessionResult] =
  ## Call only after system-core activation has completed.
  var uids: seq[SessionUid]
  for uid, entry in model.users:
    if entry.linger and entry.state in {udsStopped, udsFailed}: uids.add(uid)
  for uid in uids:
    case model.invokeStart(uid, srLingerBoot)
    of soStarted: result.add(success(saStarted))
    of soSocketInUse:
      result.add(SessionResult(ok: false, code: secPlatform,
        action: saSocketInUse, message: "user socket is already in use"))
    of soFailed:
      result.add(SessionResult(ok: false, code: secPlatform,
        action: saStartFailed, message: "user daemon failed to start"))

proc daemonExited*(model: var SessionModel; uid: SessionUid; status: int;
                   causedBySystem: bool; now: MonotonicSeconds;
                   socketInUse = false): SessionResult =
  ## Record a child exit and, if policy permits, synchronously request restart.
  if uid == 0 or not model.users.hasKey(uid): return success(saIgnoredRoot)
  model.users[uid].state = udsStopped
  let wanted = model.users[uid].sessions.len > 0 or model.users[uid].linger
  if causedBySystem or not wanted: return success(saNone)
  if status == 0:
    model.users[uid].restartBlocked = true
    return success(saNone)
  # A losing system daemon in a socket race is not a crash-budget event.
  if socketInUse:
    model.users[uid].restartBlocked = true
    return success(saSocketInUse)
  if model.users[uid].restartBlocked: return success(saNone)
  model.users[uid].pruneRestarts(now)
  if model.users[uid].restartTimes.len >= RestartLimit:
    model.users[uid].restartBlocked = true
    model.users[uid].state = udsFailed
    return success(saRestartBudgetExceeded)
  model.users[uid].restartTimes.add(now)
  case model.invokeStart(uid, srUnexpectedExit)
  of soStarted: success(saRestarted)
  of soSocketInUse:
    # Do not charge the attempt when the spawned daemon reports socket use.
    discard model.users[uid].restartTimes.pop()
    model.users[uid].restartBlocked = true
    success(saSocketInUse)
  of soFailed:
    SessionResult(ok: false, code: secPlatform, action: saStartFailed,
      message: "user daemon restart failed")

proc sessionCount*(model: SessionModel; uid: SessionUid): int =
  if model.users.hasKey(uid): model.users[uid].sessions.len else: 0

proc hasSession*(model: SessionModel; uid: SessionUid; id: SessionId): bool =
  model.users.hasKey(uid) and model.users[uid].sessions.hasKey(id)

proc snapshot*(model: SessionModel; uid: SessionUid;
               now: MonotonicSeconds): UserSnapshot =
  result.uid = uid
  if model.users.hasKey(uid):
    var entry = model.users[uid]
    entry.pruneRestarts(now)
    result.sessions = entry.sessions.len
    result.linger = entry.linger
    result.state = entry.state
    result.restartAttempts = entry.restartTimes.len
    result.restartBlocked = entry.restartBlocked
  else:
    result.state = udsStopped


proc managedUids*(model: SessionModel): seq[SessionUid] =
  ## Stable UID ordering for `users list` and deterministic shutdown.
  for uid in model.users.keys: result.add(uid)
  result.sort(system.cmp[SessionUid])

proc snapshots*(model: SessionModel; now: MonotonicSeconds): seq[UserSnapshot] =
  for uid in model.managedUids: result.add(model.snapshot(uid, now))

proc daemonStateName*(state: UserDaemonState): string =
  case state
  of udsStopped: "stopped"
  of udsStarting: "starting"
  of udsRunning: "running"
  of udsStopping: "stopping"
  of udsFailed: "failed"

proc peerPidfds*(model: SessionModel): seq[int] =
  ## Every pidfd tied to an open session, for the daemon's poll set: a pidfd
  ## becomes readable when its process exits (§7.6 step 3, `peerExited`).
  for _, entry in model.users:
    for _, session in entry.sessions:
      if session.peer.pidfd >= 0 and session.peer.pidfd notin result:
        result.add session.peer.pidfd
