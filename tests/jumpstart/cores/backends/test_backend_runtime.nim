## Real-process tests for the exec/custom backend driver (§13, §16.2, §17).
## Every adapter here is a real child process speaking the protocol over
## descriptors 3 and 4; nothing is faked.
import std/[json, monotimes, options, os, posix, sequtils, strutils, tables, times, unittest]
import ../../../../jumpstart/cores/backends/[adapter_runtime, backend_runtime],
  ../../../../jumpstart/cores/lifecycle/dispatch,
  ../../../../jumpstart/cores/manifest/[manifest, modes]
import jumpstartcore/[environment, errors, protocol, reaper, spawn]

const AdapterSource = """#!/usr/bin/env python3
import json, os, signal, sys, threading, time
inp = os.fdopen(3, "r")
out = os.fdopen(4, "w")
lock = threading.Lock()
cancelled = {}
def send(message):
    with lock:
        out.write(json.dumps(message) + "\n")
        out.flush()
hello = json.loads(inp.readline())
reply = {"type": "hello", "protocol": "jumpstart-core/1", "role": hello["role"]}
if hello["role"] == "adapter":
    reply["operations"] = os.environ["TEST_OPS"].split(",")
send(reply)
def ok(rid, result): send({"type": "response", "id": rid, "status": "ok", "result": result})
def err(rid, code, msg): send({"type": "response", "id": rid, "status": "error", "error": {"code": code, "message": msg}})
def handle(req):
    rid, op, unit = req["id"], req["op"], req["unit"]
    if op == "core.verify":
        if "TEST_ENV_FILE" in os.environ:
            with open(os.environ["TEST_ENV_FILE"], "w") as f:
                json.dump({"env": dict(os.environ), "fds": sorted(int(x) for x in os.listdir("/dev/fd")),
                           "request": req, "hello": hello}, f)
        status = open("/proc/self/status").read() if os.path.exists("/proc/self/status") else ""
        ok(rid, {"installed": True, "version": "nnp" if "NoNewPrivs:\t1" in status else "plain"})
    elif op == "unit.list":
        count = int(os.environ.get("TEST_ITEMS", "0"))
        for name in (["a", "b"] if count == 0 else ["n%d" % i for i in range(count)]):
            send({"type": "event", "id": rid, "event": "item", "field": "units",
                  "data": {"name": name, "subsystem": "service", "enablement": "enabled"}})
        ok(rid, {"units": [{"name": "c", "subsystem": "service", "enablement": "static"}]})
    elif unit == "fast":
        ok(rid, {"state": "active"})
    elif unit.startswith("slow"):
        time.sleep(1.0)
        ok(rid, {"state": "active"})
    elif unit == "hang":
        ev = cancelled.setdefault(rid, threading.Event())
        ev.wait()
        err(rid, "E_CANCELLED", "cancelled on request")
    elif unit == "hang-noack":
        time.sleep(3600)
    elif unit == "ignore-term":
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        with open(os.environ["TEST_PID_FILE"], "w") as f: f.write(str(os.getpid()))
        time.sleep(3600)
    elif unit == "term-marker":
        def onterm(*_):
            open(os.environ["TEST_PID_FILE"], "w").write("term")
            os._exit(0)
        signal.signal(signal.SIGTERM, onterm)
        time.sleep(3600)
    elif unit == "flood":
        # 3 MiB on stderr and on stdout without a single newline.
        chunk = b"x" * 65536
        for _ in range(48):
            os.write(2, chunk)
            os.write(1, chunk)
        ok(rid, {"state": "active"})
    elif unit == "crash":
        os._exit(3)
    elif unit == "unitstate":
        err(rid, "E_UNIT_STATE", "unit is masked")
    elif unit == "extra":
        ok(rid, {"state": "active", "pid": 7})
    else:
        err(rid, "E_NOT_FOUND", "no such unit")
for line in inp:
    msg = json.loads(line)
    if msg["type"] == "cancel":
        cancelled.setdefault(msg["id"], threading.Event()).set()
    elif msg["type"] == "request" and msg["unit"] in ("ignore-term", "term-marker"):
        handle(msg)  # signal handlers can only be installed by the main thread
    elif msg["type"] == "request":
        threading.Thread(target=handle, args=(msg,), daemon=True).start()
"""

proc tempRoot(name: string): string =
  result = getTempDir() / ("jumpstart-brt-" & name & "-" & $getpid())
  if dirExists(result): removeDir(result)
  createDir(result)
  discard chmod(result.cstring, Mode(0o755))

proc makeCore(name: string): CoreDirectories =
  let root = tempRoot(name)
  result = CoreDirectories(root: root / "core", stateDir: root / "state", runtimeDir: root / "run")
  for dir in [result.root, result.root / "bin", result.stateDir, result.runtimeDir]:
    createDir(dir)
    discard chmod(dir.cstring, Mode(0o755))
  writeFile(result.root / "bin" / "adapter", AdapterSource)
  discard chmod(cstring(result.root / "bin" / "adapter"), Mode(0o755))

let testMode = if getuid() == 0: cmSystem else: cmUser

proc entry(name, timeout: string; mode = manifest.emPersistent; sandbox = false;
           env: openArray[(string, string)] = []; hasSandbox = false;
           workingDirectory = ""): OperationEntry =
  var environment = initOrderedTable[string, string]()
  for (k, v) in env: environment[k] = v
  OperationEntry(name: name, backend: manifest.bkExec, executable: "bin/adapter",
    execMode: mode, common: CommonOptions(timeoutMs: parseDuration(timeout),
      hasSandbox: hasSandbox or sandbox, sandbox: sandbox, environment: environment,
      workingDirectory: workingDirectory))

const RoutedOps = "core.verify,unit.list,service.start,service.stop"

proc coreManifest(dirs: CoreDirectories; ops: seq[OperationEntry]): CoreManifest =
  CoreManifest(name: "demo", directory: dirs.root, manifestVersion: 1,
    modes: {cmSystem, cmUser}, operations: ops, account: "")

proc newRuntime(): BackendRuntime =
  var config = RuntimeConfig(mode: testMode, jumpstartVersion: "1.3.0",
    trustedUid: getuid(), runnerTrustedUid: Uid(0))
  if testMode == cmUser: config.identity = userIdentityFor(getuid())
  newBackendRuntime(config, initAdapterRuntime(modeName(testMode), "1.3.0", newReaper()))

proc standardOps(dirs: CoreDirectories; extraEnv: openArray[(string, string)] = [];
                 startTimeout = "30s"; verifySandbox = false): seq[OperationEntry] =
  var env = @[("TEST_OPS", RoutedOps), ("TEST_PID_FILE", dirs.stateDir / "pid")]
  for pair in extraEnv: env.add pair
  @[entry("core.verify", "10s", manifest.emOneshot, sandbox = verifySandbox,
          env = env, hasSandbox = true,
          workingDirectory = if verifySandbox: "/tmp" else: ""),
    entry("unit.list", "10s", env = env),
    entry("service.start", startTimeout, env = env),
    entry("service.stop", "10s", manifest.emOneshot, env = env)]

proc elapsedMs(start: MonoTime): int64 = (getMonoTime() - start).inMilliseconds

suite "exec backends with real adapter processes":
  test "one executable serving oneshot and persistent entries registers once":
    let dirs = makeCore("register")
    defer: removeDir(dirs.root.parentDir)
    let runtime = newRuntime()
    runtime.registerManifest(coreManifest(dirs, standardOps(dirs)), dirs, "")
    runtime.startPersistent("demo", monotonicMs())
    let listed = runtime.run("demo", "unit.list", "", newJObject())
    # §17.4: items precede the response's own elements.
    check listed["units"].mapIt(it["name"].getStr) == @["a", "b", "c"]
    check runtime.run("demo", "core.verify", "", newJObject())["installed"].getBool
    runtime.unloadCore("demo", monotonicMs())
    runtime.driver.waitIdle()

  test "a long item stream costs linear, not quadratic, time":
    # Copying the pending request for every `item` event made a read of N
    # entries O(N^2): 4000 entries took ~17 s in a debug build. Compare two
    # sizes instead of an absolute time so the check holds on any machine:
    # 4x the items must cost well under the 16x a quadratic loop would.
    proc streamMs(count: int): int64 =
      let dirs = makeCore("manyitems" & $count)
      defer: removeDir(dirs.root.parentDir)
      let runtime = newRuntime()
      runtime.registerManifest(coreManifest(dirs,
        standardOps(dirs, [("TEST_ITEMS", $count)])), dirs, "")
      runtime.startPersistent("demo", monotonicMs())
      let start = getMonoTime()
      let listed = runtime.run("demo", "unit.list", "", newJObject())
      result = elapsedMs(start)
      check listed["units"].len == count + 1
      check listed["units"][0]["name"].getStr == "n0"
      check listed["units"][count - 1]["name"].getStr == "n" & $(count - 1)
      runtime.unloadCore("demo", monotonicMs())
      runtime.driver.waitIdle()
    let small = streamMs(1500)
    let large = streamMs(6000)
    checkpoint "1500 items: " & $small & " ms, 6000 items: " & $large & " ms"
    check large < 8 * small + 1000

  test "persistent requests are multiplexed and unit locks serialize one unit":
    let dirs = makeCore("multiplex")
    defer: removeDir(dirs.root.parentDir)
    let runtime = newRuntime()
    runtime.registerManifest(coreManifest(dirs, standardOps(dirs)), dirs, "")
    runtime.startPersistent("demo", monotonicMs())
    let start = getMonoTime()
    let slow = runtime.dispatch("demo", "service.start", "slow-a", newJObject(), monotonicMs())
    let fast = runtime.dispatch("demo", "service.start", "fast", newJObject(), monotonicMs())
    let fastDone = runtime.waitFor(fast)
    let fastMs = elapsedMs(start)
    check fastDone.ok
    check fastMs < 900          # did not wait for the slow request
    check runtime.waitFor(slow).ok
    # Same unit twice: the second waits for the first (§11.6 unit lock).
    let t2 = getMonoTime()
    let first = runtime.dispatch("demo", "service.start", "slow-b", newJObject(), monotonicMs())
    let second = runtime.dispatch("demo", "service.start", "slow-b", newJObject(), monotonicMs())
    check runtime.waitFor(first).ok
    check runtime.waitFor(second).ok
    check elapsedMs(t2) >= 1900
    runtime.unloadCore("demo", monotonicMs())
    runtime.driver.waitIdle()

  test "client cancellation keeps the adapter's E_CANCELLED":
    let dirs = makeCore("cancel")
    defer: removeDir(dirs.root.parentDir)
    let runtime = newRuntime()
    runtime.registerManifest(coreManifest(dirs, standardOps(dirs)), dirs, "")
    runtime.startPersistent("demo", monotonicMs())
    let id = runtime.dispatch("demo", "service.start", "hang", newJObject(), monotonicMs())
    for unused in 0 .. 20:
      runtime.pump(monotonicMs()); sleep(10)
    runtime.cancel(id, monotonicMs())
    let done = runtime.waitFor(id)
    check not done.ok
    check done.code == ecCancelled
    check done.detail == "cancelled on request"
    runtime.unloadCore("demo", monotonicMs())
    runtime.driver.waitIdle()

  test "persistent timeout is E_TIMEOUT; unacknowledged cancel kills and restarts lazily":
    let dirs = makeCore("ptimeout")
    defer: removeDir(dirs.root.parentDir)
    let runtime = newRuntime()
    runtime.registerManifest(coreManifest(dirs, standardOps(dirs, startTimeout = "1s")), dirs, "")
    runtime.startPersistent("demo", monotonicMs())
    let start = getMonoTime()
    let id = runtime.dispatch("demo", "service.start", "hang-noack", newJObject(), monotonicMs())
    let done = runtime.waitFor(id)
    check done.code == ecTimeout
    check elapsedMs(start) in 900'i64 .. 2500'i64
    # The adapter ignores `cancel`: after 5 s it is killed (§13.7) and the
    # next request restarts it (§17.6).
    var killed = false
    let deadline = getMonoTime() + initDuration(seconds = 8)
    while not killed and getMonoTime() < deadline:
      runtime.pump(monotonicMs()); runtime.advance(monotonicMs())
      while runtime.driver.hasEvents:
        let event = runtime.driver.nextEvent()
        if event.kind == rekExit and event.status.kind == cekSignaled and
            event.status.code == int(SIGKILL):
          killed = true
      sleep(10)
    check killed
    check elapsedMs(start) >= 5900
    check runtime.run("demo", "service.start", "fast", newJObject())["state"].getStr == "active"
    runtime.unloadCore("demo", monotonicMs())
    runtime.driver.waitIdle()

  test "a core that floods stdout and stderr cannot grow the daemon's buffers (§19.2)":
    let dirs = makeCore("flood")
    defer: removeDir(dirs.root.parentDir)
    let runtime = newRuntime()
    runtime.registerManifest(coreManifest(dirs, standardOps(dirs)), dirs, "")
    runtime.startPersistent("demo", monotonicMs())
    let id = runtime.dispatch("demo", "service.start", "flood", newJObject(), monotonicMs())
    var stdoutBytes, stderrBytes, longest = 0
    proc drainEvents() =
      while runtime.driver.hasEvents:
        let event = runtime.driver.nextEvent()
        case event.kind
        of rekStderr: stderrBytes += event.text.len; longest = max(longest, event.text.len)
        of rekStdout: stdoutBytes += event.text.len; longest = max(longest, event.text.len)
        else: discard
    let deadline = getMonoTime() + initDuration(seconds = 30)
    while not runtime.driver.hasCompletion(id) and getMonoTime() < deadline:
      runtime.pump(monotonicMs()); runtime.advance(monotonicMs())
      drainEvents()
      sleep(1)
    check runtime.driver.hasCompletion(id)
    runtime.unloadCore("demo", monotonicMs())
    while runtime.driver.liveCount > 0:
      runtime.pump(monotonicMs()); runtime.advance(monotonicMs())
      drainEvents()
      sleep(1)
    drainEvents()
    # Unterminated output is split into records of at most 64 KiB instead of
    # being buffered whole, and none of it is lost.
    check longest <= 64 * 1024
    check stderrBytes == 48 * 65536
    check stdoutBytes == 48 * 65536

  test "unexpected exit fails in-flight requests with E_BACKEND":
    let dirs = makeCore("crash")
    defer: removeDir(dirs.root.parentDir)
    let runtime = newRuntime()
    runtime.registerManifest(coreManifest(dirs, standardOps(dirs)), dirs, "")
    runtime.startPersistent("demo", monotonicMs())
    let done = runtime.waitFor(runtime.dispatch("demo", "service.start", "crash",
      newJObject(), monotonicMs()))
    check done.code == ecBackend
    check runtime.run("demo", "service.start", "fast", newJObject())["state"].getStr == "active"
    runtime.unloadCore("demo", monotonicMs())
    runtime.driver.waitIdle()

  test "adapter error codes are preserved and result schemas enforced":
    let dirs = makeCore("codes")
    defer: removeDir(dirs.root.parentDir)
    let runtime = newRuntime()
    runtime.registerManifest(coreManifest(dirs, standardOps(dirs)), dirs, "")
    runtime.startPersistent("demo", monotonicMs())
    let masked = runtime.waitFor(runtime.dispatch("demo", "service.start", "unitstate",
      newJObject(), monotonicMs()))
    check masked.code == ecUnitState
    check masked.detail == "unit is masked"
    let extra = runtime.waitFor(runtime.dispatch("demo", "service.start", "extra",
      newJObject(), monotonicMs()))
    check extra.code == ecProtocol
    try:
      discard runtime.run("demo", "service.start", "unitstate", newJObject())
      check false
    except CoreError as e:
      check e.code == ecUnitState
    runtime.unloadCore("demo", monotonicMs())
    runtime.driver.waitIdle()

  test "oneshot timeout: SIGTERM first, SIGKILL after five seconds":
    let dirs = makeCore("oneshot")
    defer: removeDir(dirs.root.parentDir)
    var ops = standardOps(dirs)
    ops[3] = entry("service.stop", "1s", manifest.emOneshot,
      env = @[("TEST_OPS", RoutedOps), ("TEST_PID_FILE", dirs.stateDir / "pid")])
    let runtime = newRuntime()
    runtime.registerManifest(coreManifest(dirs, ops), dirs, "")
    # A process that handles SIGTERM ends on it.
    var start = getMonoTime()
    var done = runtime.waitFor(runtime.dispatch("demo", "service.stop", "term-marker",
      newJObject(), monotonicMs()))
    check done.code == ecTimeout
    runtime.driver.waitIdle()
    check readFile(dirs.stateDir / "pid") == "term"
    check elapsedMs(start) < 4000
    # A process that ignores SIGTERM is killed 5 seconds later.
    removeFile(dirs.stateDir / "pid")
    start = getMonoTime()
    done = runtime.waitFor(runtime.dispatch("demo", "service.stop", "ignore-term",
      newJObject(), monotonicMs()))
    check done.code == ecTimeout
    check elapsedMs(start) in 900'i64 .. 2500'i64
    let pid = Pid(parseInt(readFile(dirs.stateDir / "pid")))
    var signal = -1
    while runtime.driver.liveCount > 0:
      runtime.pump(monotonicMs()); runtime.advance(monotonicMs())
      while runtime.driver.hasEvents:
        let event = runtime.driver.nextEvent()
        if event.kind == rekExit and event.status.kind == cekSignaled: signal = event.status.code
      sleep(10)
    check signal == int(SIGKILL)
    check elapsedMs(start) >= 5900
    check kill(pid, 0) != 0

  test "oneshot environment is the closed §7.5/§16.2 environment with no duplicates":
    let dirs = makeCore("env")
    defer: removeDir(dirs.root.parentDir)
    putEnv("JUMPSTART_LEAK_CHECK", "daemon-only")
    let runtime = newRuntime()
    runtime.registerManifest(coreManifest(dirs, standardOps(dirs,
      extraEnv = [("TEST_ENV_FILE", dirs.stateDir / "env.json"), ("PATH", "/usr/bin:/bin")])),
      dirs, "")
    check dup2(0, 41) == 41
    discard fcntl(41, F_SETFD, 0)
    discard runtime.run("demo", "core.verify", "", %*{})
    discard close(41)
    let report = parseFile(dirs.stateDir / "env.json")
    let env = report["env"]
    check not env.hasKey("JUMPSTART_LEAK_CHECK")
    check not env.hasKey("JUMPSTART_CORE")
    check env["PATH"].getStr == "/usr/bin:/bin"          # manifest overrides base
    check env["LANG"].getStr == "C.UTF-8"
    check env["JUMPSTART_CORE_NAME"].getStr == "demo"
    check env["JUMPSTART_CORE_ROOT"].getStr == dirs.root
    check env["JUMPSTART_CORE_STATE_DIR"].getStr == dirs.stateDir
    check env["JUMPSTART_CORE_RUNTIME_DIR"].getStr == dirs.runtimeDir
    check env["JUMPSTART_MODE"].getStr == modeName(testMode)
    check env["JUMPSTART_OP"].getStr == "core.verify"
    check env["JUMPSTART_UNIT"].getStr == ""
    check env["JUMPSTART_REQUEST_ID"].getStr == report["request"]["id"].getStr
    if testMode == cmUser: check env["HOME"].getStr.len > 0
    # stdin, stdout, stderr, the protocol pair and the script descriptor (5)
    # are inherited; a daemon descriptor without FD_CLOEXEC (41) is not.
    let fds = report["fds"].getElems.mapIt(it.getInt)
    check fds[0 .. 5] == @[0, 1, 2, 3, 4, 5]
    check 41 notin fds
    check validDeadline(report["request"]["deadline"].getStr)
    check report["hello"]["role"].getStr == "adapter"

  test "sandboxed oneshot: applied on Linux, E_SANDBOX where unavailable":
    let dirs = makeCore("sandbox")
    defer: removeDir(dirs.root.parentDir)
    let runtime = newRuntime()
    runtime.registerManifest(coreManifest(dirs, standardOps(dirs,
      extraEnv = [("TEST_ENV_FILE", dirs.stateDir / "ran.json")], verifySandbox = true)), dirs, "")
    let done = runtime.waitFor(runtime.dispatch("demo", "core.verify", "", newJObject(), monotonicMs()))
    when defined(linux):
      if getuid() == 0:
        if not done.ok: checkpoint($done.code & ": " & done.detail)
        check done.ok
        if done.ok: check done.value["version"].getStr == "nnp"
      else:
        check done.ok or done.code == ecSandbox
    else:
      check done.code == ecSandbox
      check not fileExists(dirs.stateDir / "ran.json")
    runtime.driver.waitIdle()
