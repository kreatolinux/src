## The daemon in-process (jumpstart-cores §14, §19.3, §20): a fake native
## serviceHandler, requests fed through the real control server in memory, and
## the event loop driven by `runOnce`. The real binary is covered by
## test_daemon_e2e.
{.define: jumpstartTestHooks.}   # DaemonConfig.faultHook (test builds only)
import std/[json, monotimes, options, os, posix, strutils, tables, tempfiles, times, unittest]
import ../../jumpstart/cores/backends/backend_runtime,
  ../../jumpstart/cores/daemon/[daemon, daemon_calls, logging, shutdown],
  ../../jumpstart/cores/manifest/modes,
  ../../jumpstart/cores/lifecycle/routing,
  ../../jumpstart/cores/sessions/[session_manager, sessions]
import jumpstartcore/[cgroups, environment, reaper]

var logLines: seq[string]   # the daemon log of the current test

let myUid = int(getuid())
let userUid = if myUid == 0: 65534 else: myUid

type
  Fake = ref object
    calls: seq[string]
    loads: int
    onDispatch: proc(operation, unit: string) {.closure.}

proc callbacks(fake: Fake): ServiceHandlerCallbacks =
  ServiceHandlerCallbacks(
    load: proc(cgroups: Option[CoreCgroups]) = fake.loads.inc(),
    resolve: proc(name: string): ResolveReply =
      let base = if name.endsWith(".service"): name[0 ..< ^8] else: name
      if base in ["web", "slow", "fast"]:
        answered(true, base, "service", legacySuffix = name.endsWith(".service"))
      else: answered(false),
    dispatch: proc(operation, unit: string; args: JsonNode): JsonNode =
      fake.calls.add operation & " " & unit & " " & $args
      if not fake.onDispatch.isNil: fake.onDispatch(operation, unit)
      case operation
      of "unit.activate": %*{"started": 0, "failed": []}
      of "unit.deactivate": %*{"stopped": 0, "failed": []}
      of "service.status": %*{"state": "active", "detail": "", "enablement": "enabled"}
      of "service.kill", "service.enable", "service.disable": newJObject()
      else: %*{"state": "active"},
    units: proc(): seq[UnitSnapshot] = @[])

proc privateDir(path: string) =
  createDir(path)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})

proc roots(base: string): CorePathRoots =
  CorePathRoots(systemCoreRoot: base / "lib/cores", systemConfigRoot: base / "etc",
    systemStateRoot: base / "var", systemRuntimeRoot: base / "run",
    systemCgroupRoot: base / "cgroup", systemLogPath: base / "log",
    systemSocketPath: base / "jumpstart.sock", lingerRoot: base / "etc/users/linger",
    userCoreRelative: "cores", userConfigRelative: "config",
    userStateRelative: "state", userDataRelative: "data",
    fallbackRuntimeRelative: "runtime", userCgroupRoot: base / "cgroup/users")

proc newTestDaemon(base: string; fake: Fake; mode = cmSystem): Daemon =
  let paths = if mode == cmSystem: pathsFor(cmSystem, 0, roots = roots(base))
              else: pathsFor(cmUser, userUid, base / "home", roots = roots(base))
  createDir(base / "lib/cores")
  for dir in [paths.configRoot, paths.runtimeRoot, paths.stateRoot, paths.nameIndexRoot]:
    createDir(dir)
  let config = DaemonConfig(mode: mode, version: "jumpstart v2.0.0", paths: paths,
    roots: @[CoreRoot(path: base / "lib/cores", trustedUid: Uid(myUid))],
    statePaths: StatePaths(enabledDir: paths.enabledRoot, lockFile: paths.stateLock,
      trustedUid: Uid(myUid)),
    discoveryOptions: DiscoveryOptions(systemOwner: Uid(myUid)),
    trustedPeerUid: myUid, cgroupSystem: defaultCgroupSystem(),
    filesystemsReady: true,
    runtime: RuntimeConfig(mode: mode, identity: UserIdentity(uid: userUid,
      home: base / "home", user: "test", logname: "test", shell: "/bin/sh"),
      runtimeDir: paths.runtimeDir),
    native: fake.callbacks, listenFd: -1, shutdownTriggerFd: -1,
    logger: newCoreLogger(defaultCoreLogConfig(base / "log"),
      proc(path, data: string) = logLines.add data.strip))
  logLines.setLen(0)
  result = newDaemon(config, newReaper())
  result.config.logger.minimumLevel = clDebug

type Client = ref object
  lines: seq[string]
  closed: bool
  connection: ControlConnection

proc newServer(d: Daemon): ControlServer =
  newControlServer(
    proc(request: ControlRequest; context: RequestContext) = d.handleRequest(request, context),
    proc(peer: PeerCredentials): bool = peer.uid == int64(myUid))

proc send(server: ControlServer; body: JsonNode): Client =
  var request = %*{"client": {"name": "test", "version": "2.0.0"}}
  for key, value in body: request[key] = value
  let c = Client()
  c.connection = openControlConnection(server,
    PeerCredentials(uid: int64(myUid), gid: -1, pid: -1, pidfd: -1), 0,
    proc(data: string) = c.lines.add(data.strip),
    proc() = (c.closed = true))
  c.connection.feed($request & "\n", 0)
  c

proc settle(d: Daemon; done: proc(): bool; turns = 500): bool =
  for i in 0 ..< turns:
    if done(): return true
    d.runOnce(10)
  done()

proc reply(d: Daemon; c: Client): JsonNode =
  doAssert d.settle(proc(): bool = c.closed), "no response"
  parseJson(c.lines[^1])

proc ask(d: Daemon; server: ControlServer; body: JsonNode): JsonNode =
  d.reply(server.send(body))

proc service(name, action: string; args: JsonNode = nil): JsonNode =
  result = %*{"service": {"name": name, "action": action}}
  if not args.isNil: result["service"]["args"] = args

proc code(r: JsonNode): string = r{"error"}{"code"}.getStr

proc started(d: Daemon): bool =
  result = d.settle(proc(): bool = d.idle and d.stateOf("serviceHandler") == csLoaded)
  if not result:
    for line in logLines: echo "  log: ", line

suite "daemon routing and dispatch":
  test "serviceHandler loads from the event loop; native calls get typed arguments":
    let base = createTempDir("jsd-", "")
    defer: removeDir(base)
    let fake = Fake()
    let d = newTestDaemon(base, fake)
    let server = d.newServer
    d.startup()
    check d.started
    check fake.loads == 1
    var activated = false                                # §20.6 activation
    for call in fake.calls:
      if call.startsWith("unit.activate"): activated = true
    check activated
    let r = d.ask(server, service("web", "start"))
    check r["status"].getStr == "ok"
    check r["core"].getStr == "serviceHandler"
    check fake.calls[^1] == "service.start web {}"
    check d.ask(server, service("web.service", "status"))["status"].getStr == "ok"
    discard d.ask(server, service("web", "kill"))
    check fake.calls[^1] == "service.kill web {\"signal\":\"SIGTERM\"}"
    discard d.ask(server, service("web", "kill", %*{"signal": "SIGKILL"}))
    check fake.calls[^1] == "service.kill web {\"signal\":\"SIGKILL\"}"
    discard d.ask(server, %*{"service": {"name": "web", "action": "enable", "now": "true"}})
    check fake.calls[^1] == "service.enable web {\"now\":true}"
    discard d.ask(server, service("web", "disable", %*{"now": "false"}))
    check fake.calls[^1] == "service.disable web {\"now\":false}"
    check d.ask(server, service("serviceHandler/web", "stop"))["core"].getStr == "serviceHandler"
    check d.ask(server, service("nothing", "start")).code == "E_NOT_FOUND"
    check d.ask(server, service("ghost/web", "start")).code == "E_NOT_FOUND"
    check d.ask(server, service("web", "frobnicate")).code == "E_USAGE"
    let listed = d.ask(server, %*{"core": {"action": "list-loaded"}})
    check listed["result"]["cores"][0]["name"].getStr == "serviceHandler"

  test "enabled cores that were not discovered fail; others still load":
    let base = createTempDir("jsd-", "", getAppDir())   # /tmp is world-writable (§8.3)
    defer: removeDir(base)
    let fake = Fake()
    let d = newTestDaemon(base, fake)
    privateDir(base / "etc/cores")
    privateDir(base / "etc/cores/enabled")
    for name in ["serviceHandler", "ghost"]: writeFile(base / "etc/cores/enabled" / name, "")
    let server = d.newServer
    d.startup()
    check d.started
    let status = d.ask(server, %*{"core": {"action": "status", "name": "ghost"}})
    check status["result"]["cores"][0]["state"].getStr == "failed"
    check status["result"]["cores"][0]["error"]["code"].getStr == "E_NOT_FOUND"

  test "E_STATE loads serviceHandler only and reports the error":
    let base = createTempDir("jsd-", "")
    defer: removeDir(base)
    let d = newTestDaemon(base, Fake())
    privateDir(base / "etc/cores")
    privateDir(base / "etc/cores/enabled")
    writeFile(base / "etc/cores/enabled/demo", "not empty")
    let server = d.newServer
    d.startup()
    check d.started
    let r = d.ask(server, %*{"core": {"action": "status"}})
    check r["result"]["state_error"]["code"].getStr == "E_STATE"
    check d.enabled == @["serviceHandler"]

  test "an exception without a code is E_IO for filesystem errors and E_BACKEND otherwise (§18)":
    let base = createTempDir("jsd-", "")
    defer: removeDir(base)
    let fake = Fake()
    let d = newTestDaemon(base, fake)
    let server = d.newServer
    d.startup()
    check d.started
    var failure = 0
    fake.onDispatch = proc(operation, unit: string) =
      if operation == "service.start":
        case failure
        of 0: raise newException(OSError, "no space left on device")
        of 1: raise newException(IOError, "socket closed")
        else: raise newException(ValueError, "unexpected state")
    check d.ask(server, service("web", "start")).code == "E_IO"
    failure = 1
    check d.ask(server, service("web", "start")).code == "E_IO"
    failure = 2
    check d.ask(server, service("web", "start")).code == "E_BACKEND"

suite "daemon request policy":
  test "mode policy, core actions and the user environment store":
    let base = createTempDir("jsd-", "")
    defer: removeDir(base)
    let sys = newTestDaemon(base / "s", Fake())
    let sysServer = sys.newServer
    sys.startup()
    check sys.started
    check sys.ask(sysServer, %*{"env": {"action": "list"}}).code == "E_USAGE"
    check sys.ask(sysServer, %*{"core": {"action": "enable", "name": "x"}}).code == "E_USAGE"
    check sys.ask(sysServer, %*{"users": {"action": "list"}})["result"]["users"].len == 0
    let user = newTestDaemon(base / "u", Fake(), cmUser)
    let server = user.newServer
    user.startup()
    check user.started
    check user.ask(server, %*{"power": {"action": "reboot"}}).code == "E_USAGE"
    check user.ask(server, %*{"users": {"action": "list"}}).code == "E_USAGE"
    check user.ask(server, %*{"env": {"action": "set", "vars": {"A": "1"}}})["status"].getStr == "ok"
    check user.userEnv["A"] == "1"
    check user.ask(server, %*{"env": {"action": "set", "vars": {"JUMPSTART_X": "1"}}}).code == "E_USAGE"
    check user.ask(server, %*{"env": {"action": "unset", "vars": {"A": nil}}})["status"].getStr == "ok"
    check user.userEnv.len == 0

  test "native mutating operations serialize per unit (§11.6); other units and reads run alongside":
    let base = createTempDir("jsd-", "")
    defer: removeDir(base)
    let fake = Fake()
    let d = newTestDaemon(base, fake)
    let server = d.newServer
    d.startup()
    check d.started
    var sameUnit, otherUnit, reader: Client
    var order: seq[string]
    fake.onDispatch = proc(operation, unit: string) =
      order.add operation & ":" & unit
      if operation == "service.start" and unit == "slow" and sameUnit.isNil:
        # While `slow` runs, a second start of it, a start of another unit and
        # a read arrive. Only the second start waits for the unit lock.
        sameUnit = server.send(service("slow", "start"))
        otherUnit = server.send(service("fast", "start"))
        reader = server.send(service("web", "status"))
        for i in 0 ..< 20: d.nativePump()
        order.add "slow:done"
    let first = d.ask(server, service("slow", "start"))
    check first["status"].getStr == "ok"
    check d.reply(sameUnit)["status"].getStr == "ok"
    check d.reply(otherUnit)["status"].getStr == "ok"
    check d.reply(reader)["status"].getStr == "ok"
    check order == @["service.start:slow", "service.status:web", "service.start:fast",
      "slow:done", "service.start:slow"]

  test "an internal call made while a native operation of the unit is suspended runs at once (§11.6)":
    # callSync normally waits for the unit lock like a client call. Here the
    # lock holder is the frame below it, which cannot finish until this frame
    # returns, so waiting would deadlock: the call runs in the frame that needs
    # it, in order, and the outer operation then completes.
    let base = createTempDir("jsd-", "")
    defer: removeDir(base)
    let fake = Fake()
    let d = newTestDaemon(base, fake)
    let server = d.newServer
    d.startup()
    check d.started
    var order: seq[string]
    var nested: CallResult
    var nestedRan = false
    fake.onDispatch = proc(operation, unit: string) =
      order.add operation & ":" & unit
      if operation == "service.start" and unit == "slow" and not nestedRan:
        nestedRan = true
        nested = d.callSync("serviceHandler", "service.stop", "slow", newJObject(),
          deadlineMs = getMonoTime().ticks div 1_000_000 + 3000)
        order.add "nested:done"
    check d.ask(server, service("slow", "start"))["status"].getStr == "ok"
    check order == @["service.start:slow", "service.stop:slow", "nested:done"]
    check nested.ok

  test "a client that disconnects cancels its request waiting for a unit lock":
    let base = createTempDir("jsd-", "")
    defer: removeDir(base)
    let fake = Fake()
    let d = newTestDaemon(base, fake)
    let server = d.newServer
    d.startup()
    check d.started
    var queued: Client
    fake.onDispatch = proc(operation, unit: string) =
      if unit == "slow" and queued.isNil:
        queued = server.send(service("slow", "stop"))
        d.nativePump()
        queued.connection.disconnect()
        for i in 0 ..< 5: d.nativePump()
    check d.ask(server, service("slow", "start"))["status"].getStr == "ok"
    for i in 0 ..< 20: d.runOnce(5)
    for call in fake.calls: check not call.startsWith("service.stop slow")

  test "shutdown admits only status requests and unloads the cores":
    let base = createTempDir("jsd-", "")
    defer: removeDir(base)
    let fake = Fake()
    let d = newTestDaemon(base, fake, cmUser)
    let server = d.newServer
    d.startup()
    check d.started
    d.requestShutdown(stSigTerm)
    check d.ask(server, service("web", "start")).code == "E_SHUTDOWN"
    check d.ask(server, service("web", "status"))["status"].getStr == "ok"
    d.serve()
    check d.exitRequested
    check d.stateOf("serviceHandler") == csUnloaded
    check fake.calls[^1].startsWith("unit.deactivate")

suite "daemon robustness":
  test "an exception in a loop step is logged and the loop keeps serving":
    let base = createTempDir("jsd-", "")
    defer: removeDir(base)
    let d = newTestDaemon(base, Fake())
    let server = d.newServer
    d.startup()
    check d.started
    var faults = 0
    d.config.faultHook = proc() =
      inc faults
      if faults == 1: raise newException(ValueError, "injected")
      if faults == 2: raise newException(AssertionDefect, "injected defect")
    d.runOnce(0)
    d.runOnce(0)
    d.runOnce(0)
    check faults >= 3
    check d.faultCount == 2
    var logged = 0
    for line in logLines:
      if line.contains("event loop fault"): inc logged
    check logged == 2
    check d.ask(server, service("web", "status"))["status"].getStr == "ok"
    check not d.exitRequested

  test "waits inside cgroup kills and removals keep the event loop running":
    let base = createTempDir("jsd-", "")
    defer: removeDir(base)
    let d = newTestDaemon(base, Fake())
    d.startup()
    check d.started
    var turns = 0
    d.config.faultHook = proc() = inc turns
    d.config.cgroupSystem.pause(1)       # what killCgroup/removeCgroupTree call
    check turns == 1

  test "every operation logs a start line and a completion line (§19.2)":
    let base = createTempDir("jsd-", "")
    defer: removeDir(base)
    let d = newTestDaemon(base, Fake())
    let server = d.newServer
    d.startup()
    check d.started
    check d.ask(server, service("web", "start"))["status"].getStr == "ok"
    var start, complete = ""
    for line in logLines:
      if line.contains("operation=service.start unit=web"):
        if line.contains("event=start"): start = line
        if line.contains("event=complete"): complete = line
    check start.len > 0
    check start.contains("request_id=") and start.contains("backend=native")
    check complete.contains("result=ok") and complete.contains("duration_ms=")
    # A failure carries the error name.
    discard d.ask(server, service("web", "kill", %*{"signal": "SIGKILL"}))
    check d.ask(server, service("nothing", "start")).code == "E_NOT_FOUND"

  test "a shutdown request ends queued loads and answers their requests":
    let base = createTempDir("jsd-", "")
    defer: removeDir(base)
    let fake = Fake()
    let d = newTestDaemon(base, fake, cmUser)
    let server = d.newServer
    d.startup()                      # serviceHandler's load is queued
    let queued = server.send(%*{"core": {"action": "load", "name": "ghost"}})
    d.requestShutdown(stSigTerm)
    check d.reply(queued).code == "E_SHUTDOWN"
    d.serve()
    check d.exitRequested
    check fake.loads == 0            # no queued load ran
    check d.stateOf("serviceHandler") == csUnloaded

  test "routing re-reads the enabled set, so local enable/disable is seen":
    let base = createTempDir("jsd-", "")
    defer: removeDir(base)
    let d = newTestDaemon(base, Fake())
    let server = d.newServer
    d.startup()
    check d.started
    check d.enabled == @["serviceHandler"]
    privateDir(base / "etc/cores")
    privateDir(base / "etc/cores/enabled")
    for name in ["serviceHandler", "ghost"]: writeFile(base / "etc/cores/enabled" / name, "")
    check d.ask(server, service("web", "status"))["status"].getStr == "ok"
    check d.enabled == @["ghost", "serviceHandler"]
    removeFile(base / "etc/cores/enabled/ghost")
    check d.ask(server, service("web", "status"))["status"].getStr == "ok"
    check d.enabled == @["serviceHandler"]

  test "when discovery fails, enabled cores report the real error code":
    let base = createTempDir("jsd-", "")
    defer: removeDir(base)
    let d = newTestDaemon(base, Fake())
    let server = d.newServer
    privateDir(base / "etc/cores")
    privateDir(base / "etc/cores/enabled")
    for name in ["serviceHandler", "ghost"]: writeFile(base / "etc/cores/enabled" / name, "")
    createDir(base / "lib/cores")
    setFilePermissions(base / "lib/cores", {fpUserRead, fpUserWrite, fpUserExec,
      fpGroupRead, fpGroupWrite, fpGroupExec, fpOthersRead, fpOthersWrite, fpOthersExec})
    d.startup()
    check d.started
    let status = d.ask(server, %*{"core": {"action": "status", "name": "ghost"}})
    check status["result"]["cores"][0]["state"].getStr == "failed"
    check status["result"]["cores"][0]["error"]["code"].getStr == "E_PERMISSION"

  test "children nobody registered are reaped and logged at debug (§15.3)":
    let base = createTempDir("jsd-", "")
    defer: removeDir(base)
    let d = newTestDaemon(base, Fake())
    d.startup()
    check d.started
    let pid = posix.fork()
    if pid == 0: posix.exitnow(0)
    check pid > 0
    var seen = false
    for i in 0 ..< 200:
      d.runOnce(10)
      for line in logLines:
        if line.contains("reaped unowned child pid " & $pid): seen = true
      if seen: break
    check seen

  test "`users list` reads the linger markers again":
    let base = createTempDir("jsd-", "")
    defer: removeDir(base)
    let d = newTestDaemon(base, Fake())
    let server = d.newServer
    var markers: seq[string]
    var stops = 0
    let account = AccountInfo(uid: 4242, gid: 4242, name: "alice", home: "/home/alice",
      shell: "/bin/sh")
    d.attachSessions(initSessionManager(
      AccountOps(byName: proc(name: string): AccountInfo =
                   if name == "alice": account else: raise newException(KeyError, name),
                 byUid: proc(uid: SessionUid): AccountInfo =
                   if uid == 4242: account else: raise newException(KeyError, $uid)),
      PeerOps(),
      LingerFs(listNames: proc(): seq[string] = markers,
               createMarker: proc(name: string) = discard,
               removeMarker: proc(name: string) = discard),
      SessionRuntimeOps(
        start: proc(account: AccountInfo; reason: StartReason): StartOutcome = soStarted,
        stop: proc(account: AccountInfo) = inc stops)))
    markers = @["alice"]               # a lingering user at boot
    d.startup()
    check d.started
    let listed = d.ask(server, %*{"users": {"action": "list"}})["result"]["users"]
    check listed.len == 1
    check listed[0]["user"].getStr == "alice"
    check listed[0]["linger"].getBool
    markers = @[]                      # `jumpctl users linger disable alice`
    check d.ask(server, %*{"users": {"action": "list"}})["result"]["users"].len == 0
    check stops == 1                   # no sessions: its daemon stops
    markers = @["alice"]               # `jumpctl users linger enable alice`
    discard d.ask(server, %*{"users": {"action": "list"}})
    check d.sessions.model.snapshot(SessionUid(4242), 0).linger
