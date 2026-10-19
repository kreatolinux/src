import std/unittest
import ../../../../jumpstart/cores/sessions/sessions

proc peer(fd: int; source = psPeerPidfd; peerUid = 0'u32;
          started = 1'i64; accepted = 2'i64): PeerMetadata =
  PeerMetadata(pid: fd + 100, pidfd: fd, peerUid: peerUid, source: source,
    processStart: started, acceptedAt: accepted)

suite "user daemon session model":
  test "UID zero succeeds without state or platform actions":
    var starts, releases = 0
    let ops = PlatformOps(
      startUser: proc(uid: SessionUid; why: StartReason): StartOutcome =
        inc starts
        soStarted,
      releasePeer: proc(fd: int) = inc releases)
    var model = initSessionModel(ops)
    let opened = model.openSession(0, "root", peer(10), 0)
    check opened.ok
    check opened.action == saIgnoredRoot
    check model.sessionCount(0) == 0
    check starts == 0
    check releases == 1
    check model.closeSession(0, "root").action == saIgnoredRoot

  test "sessions are keyed per UID and own peer metadata":
    var starts: seq[(SessionUid, StartReason)]
    var released: seq[int]
    let ops = PlatformOps(
      startUser: proc(uid: SessionUid; why: StartReason): StartOutcome =
        starts.add((uid, why))
        soStarted,
      releasePeer: proc(fd: int) = released.add(fd))
    var model = initSessionModel(ops)
    check model.openSession(1000, "login", peer(1), 0).action == saStarted
    check model.openSession(1000, "ssh", peer(2), 1).action == saOpened
    check model.openSession(1001, "login", peer(3), 1).action == saStarted
    check model.sessionCount(1000) == 2
    check model.sessionCount(1001) == 1
    check starts == @[(1000'u32, srFirstSession), (1001'u32, srFirstSession)]

    let duplicate = model.openSession(1000, "login", peer(4), 2)
    check not duplicate.ok
    check duplicate.code == secAlreadyOpen
    check released == @[4]
    check model.sessionCount(1000) == 2

  test "fallback peer validation rejects non-root and PID reuse":
    var released: seq[int]
    var model = initSessionModel(PlatformOps(
      releasePeer: proc(fd: int) = released.add(fd)))
    let reused = model.openSession(1000, "a",
      peer(5, psPeerCredFallback, started = 10, accepted = 10), 0)
    let untrusted = model.openSession(1000, "b", peer(6, peerUid = 1000), 0)
    check not reused.ok
    check reused.code == secPermission
    check not untrusted.ok
    check released == @[5, 6]
    check model.sessionCount(1000) == 0
    check model.openSession(1000, "ok",
      peer(7, psPeerCredFallback, started = 9, accepted = 10), 0).ok

  test "last close stops only a non-lingering user":
    var stopped: seq[SessionUid]
    var released: seq[int]
    var model = initSessionModel(PlatformOps(
      stopUser: proc(uid: SessionUid) = stopped.add(uid),
      releasePeer: proc(fd: int) = released.add(fd)))
    discard model.openSession(42, "a", peer(1), 0)
    discard model.openSession(42, "b", peer(2), 0)
    check model.closeSession(42, "a").action == saClosed
    check stopped.len == 0
    check model.closeSession(42, "b").action == saStopped
    check stopped == @[42'u32]
    check released == @[1, 2]
    check model.snapshot(42, 0).state == udsStopped

  test "pidfd readiness closes every session belonging to the peer":
    var stops = 0
    var model = initSessionModel(PlatformOps(
      stopUser: proc(uid: SessionUid) = inc stops))
    discard model.openSession(1000, "a", peer(8), 0)
    discard model.openSession(1000, "b", peer(8), 0)
    let changes = model.peerExited(8)
    check changes.len == 2
    check model.sessionCount(1000) == 0
    check stops == 1

  test "linger defers stop and starts only when boot hook runs":
    var reasons: seq[StartReason]
    var stops = 0
    let ops = PlatformOps(
      startUser: proc(uid: SessionUid; why: StartReason): StartOutcome =
        reasons.add(why)
        soStarted,
      stopUser: proc(uid: SessionUid) = inc stops)
    var model = initSessionModel(ops)
    discard model.setLinger(1000, true)
    check reasons.len == 0
    let boot = model.startLingeringUsers()
    check boot.len == 1
    check boot[0].action == saStarted
    check reasons == @[srLingerBoot]
    discard model.openSession(1000, "a", peer(1), 0)
    check model.closeSession(1000, "a").action == saClosed
    check stops == 0
    check model.setLinger(1000, false).action == saStopped
    check stops == 1

  test "unexpected exits have five restarts in a rolling sixty seconds":
    var starts = 0
    var model = initSessionModel(PlatformOps(
      startUser: proc(uid: SessionUid; why: StartReason): StartOutcome =
        inc starts
        soStarted))
    discard model.openSession(1000, "a", peer(1), 0)
    for second in 0 ..< RestartLimit:
      check model.daemonExited(1000, 1, false, second).action == saRestarted
    check starts == 1 + RestartLimit
    let denied = model.daemonExited(1000, 1, false, 5)
    check denied.action == saRestartBudgetExceeded
    check model.snapshot(1000, 5).restartAttempts == RestartLimit
    check model.snapshot(1000, 5).restartBlocked

    # A newly opened session is the specified retry trigger and fresh budget.
    check model.openSession(1000, "b", peer(2), 6).action == saStarted
    check not model.snapshot(1000, 6).restartBlocked
    check model.snapshot(1000, 6).restartAttempts == 0
    check model.daemonExited(1000, 1, false, 6).action == saRestarted

  test "restart timestamps age out at the sixty second boundary":
    var model = initSessionModel()
    discard model.openSession(1000, "a", peer(1), 0)
    for second in 0 ..< RestartLimit:
      discard model.daemonExited(1000, 1, false, second)
    check model.daemonExited(1000, 1, false, 60).action == saRestarted
    check model.snapshot(1000, 60).restartAttempts == RestartLimit

  test "clean, intentional, and socket-race exits do not restart":
    var starts = 0
    var model = initSessionModel(PlatformOps(
      startUser: proc(uid: SessionUid; why: StartReason): StartOutcome =
        inc starts
        soStarted))
    discard model.openSession(1000, "a", peer(1), 0)
    check model.daemonExited(1000, 0, false, 0).action == saNone
    check starts == 1
    check model.openSession(1000, "b", peer(2), 1).action == saStarted
    check model.daemonExited(1000, 1, true, 1).action == saNone
    check starts == 2
    # Explicitly start it again, then emulate the child reporting socket use.
    check model.openSession(1000, "c", peer(3), 2).action == saStarted
    check model.daemonExited(1000, 1, false, 2, socketInUse = true).action == saSocketInUse
    check model.snapshot(1000, 2).restartAttempts == 0
    check starts == 3

  test "platform startup failures retain sessions for a later retry":
    var outcomes = @[soFailed, soSocketInUse, soStarted]
    var model = initSessionModel(PlatformOps(
      startUser: proc(uid: SessionUid; why: StartReason): StartOutcome =
        result = outcomes[0]
        outcomes.delete(0)))
    let first = model.openSession(1000, "a", peer(1), 0)
    check not first.ok
    check first.action == saStartFailed
    check model.sessionCount(1000) == 1
    let second = model.openSession(1000, "b", peer(2), 1)
    check not second.ok
    check second.action == saSocketInUse
    check model.sessionCount(1000) == 2
    check model.openSession(1000, "c", peer(3), 2).action == saStarted

import std/[json, os, strutils, tables]
import posix
import ../../../../jumpstart/cores/cli/cli,
  ../../../../jumpstart/cores/daemon/control,
  ../../../../jumpstart/cores/sessions/[lingerfs, session_manager]
import jumpstartcore/[errors, peercred]

suite "session cleanup":
  test "a last close after the daemon already exited still releases resources":
    var stops = 0
    var model = initSessionModel(PlatformOps(
      startUser: proc(uid: SessionUid; why: StartReason): StartOutcome = soStarted,
      stopUser: proc(uid: SessionUid) = inc stops))
    discard model.openSession(1000, "a", peer(1), 0)
    check model.daemonExited(1000, 0, false, 1).action == saNone  # clean exit
    check model.snapshot(1000, 1).state == udsStopped
    check model.closeSession(1000, "a").action == saStopped
    check stops == 1

suite "linger markers":
  proc lingerDir(): string =
    result = getTempDir() / ("jumpstart-linger-" & $getCurrentProcessId())
    if dirExists(result): removeDir(result)

  test "markers are root-owned empty regular files; everything else is ignored":
    let root = lingerDir()
    defer: removeDir(root)
    let owner = int(getuid())     # stands in for root in an unprivileged test
    var logs: seq[string]
    let fs = lingerFs(root, owner, proc(m: string) = logs.add m)
    check fs.listNames().len == 0
    fs.createMarker("alice")
    fs.createMarker("alice")      # idempotent
    var st: Stat
    check lstat((root / "alice").cstring, st) == 0 and st.st_size == 0
    writeFile(root / "bob", "not empty")
    createSymlink(root / "alice", root / "carol")
    createDir(root / "dave")
    writeFile(root / "bad name", "")
    check fs.listNames() == @["alice"]
    check logs.len == 4
    check validLingerName("svc-user_1") and not validLingerName("root") and
      not validLingerName("../x") and not validLingerName("")
    expect ValueError: fs.createMarker("../etc")
    fs.removeMarker("alice")
    fs.removeMarker("alice")      # absent is fine
    check fs.listNames().len == 0
    # Markers owned by anyone but the expected owner are not trusted.
    writeFile(root / "erin", "")
    check lingerFs(root, owner + 1).listNames().len == 0

  test "a group- or world-writable linger directory is not trusted":
    let root = lingerDir()
    defer: removeDir(root)
    let owner = int(getuid())
    lingerFs(root, owner).createMarker("alice")
    check posix.chmod(root.cstring, Mode(0o777)) == 0
    var logs: seq[string]
    check lingerFs(root, owner, proc(m: string) = logs.add m).listNames().len == 0
    check logs.len == 1
    expect IOError: lingerFs(root, owner).createMarker("bob")

suite "peer credentials and pidfds":
  test "peer credentials of a socketpair are our own":
    var fds: array[2, cint]
    check socketpair(posix.AF_UNIX, posix.SOCK_STREAM, 0, fds) == 0
    defer:
      discard posix.close(fds[0]); discard posix.close(fds[1])
    let cred = peerCredentials(fds[0])
    check cred.uid == int64(getuid())
    check cred.gid == int64(getgid())
    check cred.pid == int(getpid())

  test "proc stat parsing tolerates hostile comm fields":
    let stat = "42 (evil) ) (x) S 1 42 42 0 -1 4194560 0 0 0 0 0 0 0 0 20 0 1 0 98765 0 0"
    check parseStatStartTime(stat) == 98765
    check parseStatState(stat) == 'S'
    check parseStatFlags(stat) == 4194560'u64
    check parseStatusRealUid("Name:\tx\nUid:\t0\t1000\t0\t0\n") == 0
    expect ValueError: discard parseStatStartTime("garbage")

  when defined(linux):
    test "pidfds and start times on Linux":
      let fd = pidfdOpen(int(getpid()))
      if fd >= 0:
        check not pidfdExited(fd)
        discard posix.close(fd)
      check processStartTicks(int(getpid())) <= bootTimeTicks()
      check processRealUid(int(getpid())) == int64(getuid())

    test "a session whose peer PID was reused before pidfd_open is rejected":
      var manager = initSessionManager(AccountOps(
        byUid: proc(uid: SessionUid): AccountInfo =
          AccountInfo(uid: uid, gid: uid, name: "u" & $uid, home: "/home/u")),
        procPeerOps(), LingerFs(), SessionRuntimeOps(
          start: proc(a: AccountInfo; r: StartReason): StartOutcome = soStarted,
          stop: proc(a: AccountInfo) = discard))
      let acceptedAt = bootTimeTicks()
      sleep(30)
      # A process started after the connection was accepted holds the PID now.
      let pid = fork()
      if pid == 0:
        sleep(2000)
        quit(0)
      sleep(30)
      let response = manager.handleSession(SessionRequest(action: "open", uid: 1000, id: "s"),
        AcceptedPeer(pid: int(pid), uid: 0, acceptedAt: acceptedAt, peerPidfd: -1), 0)
      check response.status == rsError
      check response.error.code == ecPermission
      discard posix.kill(pid, SIGKILL)
      var raw: cint
      discard waitpid(pid, raw, 0)
      if getuid() == 0:
        # Our own (earlier-started, root) process is accepted.
        let ok = manager.handleSession(SessionRequest(action: "open", uid: 1000, id: "s2"),
          AcceptedPeer(pid: int(getpid()), uid: 0, acceptedAt: bootTimeTicks(), peerPidfd: -1), 0)
        check ok.status == rsOk
        check manager.model.sessionCount(1000) == 1

suite "session request errors (§18)":
  test "a session id that is not open is E_UNIT_STATE, not E_STATE":
    var manager = initSessionManager(AccountOps(
      byUid: proc(uid: SessionUid): AccountInfo =
        AccountInfo(uid: uid, gid: uid, name: "u" & $uid, home: "/home/u")),
      PeerOps(closeFd: proc(fd: int) = discard), LingerFs(), SessionRuntimeOps(
        start: proc(a: AccountInfo; r: StartReason): StartOutcome = soStarted,
        stop: proc(a: AccountInfo) = discard))
    let response = manager.handleSession(SessionRequest(action: "close", uid: 1000, id: "nope"),
      AcceptedPeer(pid: 1, uid: 0, acceptedAt: 0, peerPidfd: -1), 0)
    check response.status == rsError
    check response.error.code == ecUnitState

suite "users listing (§21.8)":
  test "usersJson only emits states the CLI formats, for every daemon state":
    var outcomes = initTable[SessionUid, StartOutcome]()
    var manager = initSessionManager(AccountOps(
      byName: proc(name: string): AccountInfo =
        AccountInfo(uid: (if name == "lingerer": 2000'u32 else: 1000'u32), gid: 1,
          name: name, home: "/home/" & name),
      byUid: proc(uid: SessionUid): AccountInfo =
        AccountInfo(uid: uid, gid: 1, name: "u" & $uid, home: "/home/u")),
      PeerOps(closeFd: proc(fd: int) = discard),
      LingerFs(createMarker: proc(name: string) = discard,
               removeMarker: proc(name: string) = discard,
               listNames: proc(): seq[string] = @[]),
      SessionRuntimeOps(
        start: proc(a: AccountInfo; r: StartReason): StartOutcome = outcomes[a.uid],
        stop: proc(a: AccountInfo) = discard))
    outcomes[1000] = soStarted
    outcomes[1001] = soSocketInUse     # hand-started daemon holds the socket
    outcomes[1002] = soFailed
    outcomes[1003] = soStarted
    for (uid, id, fd) in [(1000'u32, "a", 1), (1001'u32, "b", 2), (1002'u32, "c", 3),
                          (1003'u32, "d", 4)]:
      discard manager.model.openSession(uid, id,
        PeerMetadata(pid: fd + 100, pidfd: fd, peerUid: 0, source: psPeerPidfd,
          processStart: 1, acceptedAt: 2), 0)
    # 1003's daemon exits cleanly: it is not restarted before the next session.
    discard manager.model.daemonExited(1003, 0, false, 0)
    # Lingering user whose daemon has not been started yet.
    discard manager.setLingerMarker("lingerer", true)
    var states: seq[string]
    let rows = manager.usersJson(0)
    for row in rows: states.add $row["uid"].getInt & ":" & row["state"].getStr
    check states == @["1000:running", "1001:starting", "1002:failed", "1003:failed",
                      "2000:starting"]
    # No row carries a state the CLI rejects, and the whole listing formats.
    check formatUsers(%*{"users": rows}) ==
      "1000 1000 1 running -\n1001 1001 1 starting -\n1002 1002 1 failed -\n" &
      "1003 1003 1 failed -\n2000 lingerer 0 starting linger\n"
    # A user with neither sessions nor linger has no row.
    discard manager.model.closeSession(1000, "a")
    check manager.usersJson(0).len == 4
    # An unfamiliar state does not fail the whole listing.
    check formatUsers(%*{"users": [
      {"uid": 5, "user": "a", "sessions": 0, "state": "running", "linger": true},
      {"uid": 6, "user": "b", "sessions": 1, "state": "stopped", "linger": false}]}) ==
      "5 a 0 running linger\n6 b 1 stopped -\n"
