## Tests for `local_run` (§21.15): resolving and running one operation of one
## core without the daemon. Adapters are real child processes; manifests are
## built in memory, and cores come from an injected loader.
import std/[json, os, posix, strutils, tables, times, unittest]
import ../../../../jumpstart/cores/backends/backend_runtime,
  ../../../../jumpstart/cores/cli/local_run,
  ../../../../jumpstart/cores/manifest/[manifest, modes]
import jumpstartcore/[errors, spawn]

const AdapterSource = """#!/usr/bin/env python3
import json, os, sys, threading, time
inp = os.fdopen(3, "r")
out = os.fdopen(4, "w")
lock = threading.Lock()
cancelled = {}
def send(message):
    with lock:
        out.write(json.dumps(message) + "\n")
        out.flush()
hello = json.loads(inp.readline())
with open(os.environ["TEST_PID_FILE"], "w") as f: f.write(str(os.getpid()))
reply = {"type": "hello", "protocol": "jumpstart-core/1", "role": hello["role"]}
if hello["role"] == "adapter":
    reply["operations"] = os.environ["TEST_OPS"].split(",")
send(reply)
def ok(rid, result): send({"type": "response", "id": rid, "status": "ok", "result": result})
def err(rid, code, msg): send({"type": "response", "id": rid, "status": "error", "error": {"code": code, "message": msg}})
def handle(req):
    rid, op, unit = req["id"], req["op"], req["unit"]
    if op == "unit.list":
        for name in ("a", "b"):
            send({"type": "event", "id": rid, "event": "item", "field": "units",
                  "data": {"name": name, "subsystem": "service", "enablement": "enabled"}})
        ok(rid, {"units": [{"name": "c", "subsystem": "service", "enablement": "static"}]})
    elif op == "log.follow":
        send({"type": "event", "id": rid, "event": "entry",
              "data": {"time": "T", "level": "info", "unit": unit, "message": "one"}})
        cancelled.setdefault(rid, threading.Event()).wait()
        err(rid, "E_CANCELLED", "cancelled on request")
    elif op == "service.status" and unit == "hang":
        cancelled.setdefault(rid, threading.Event()).wait()
        err(rid, "E_CANCELLED", "cancelled on request")
    elif op == "service.status" and unit == "rtdir":
        d = os.environ["JUMPSTART_CORE_RUNTIME_DIR"]
        ok(rid, {"state": "active", "enablement": "enabled",
                 "detail": oct(os.stat(d).st_mode & 0o777) if os.path.isdir(d) else "absent"})
    elif op == "service.status" and unit == "bogus":
        ok(rid, {"state": "nonsense", "detail": "", "enablement": "enabled"})
    elif op == "service.status" and unit == "badevent":
        send({"type": "event", "id": rid, "event": "item", "field": "units", "data": {"name": "x"}})
        ok(rid, {"state": "active", "detail": "", "enablement": "enabled"})
    elif op == "service.status":
        ok(rid, {"state": "active", "detail": unit, "enablement": "enabled"})
    else:
        err(rid, "E_BACKEND", "unexpected " + op)
for line in inp:
    msg = json.loads(line)
    if msg["type"] == "cancel":
        cancelled.setdefault(msg["id"], threading.Event()).set()
    elif msg["type"] == "request":
        threading.Thread(target=handle, args=(msg,), daemon=True).start()
"""

let testMode = if getuid() == 0: cmSystem else: cmUser
let base = getTempDir() / ("jumpstart-local-run-" & $getpid())

proc exec(name, timeout: string; mode = manifest.emPersistent; env: seq[(string, string)] = @[]): OperationEntry =
  var environment = initOrderedTable[string, string]()
  for (k, v) in env: environment[k] = v
  OperationEntry(name: name, backend: manifest.bkExec, executable: "bin/adapter",
    execMode: mode, common: CommonOptions(timeoutMs: parseDuration(timeout), environment: environment))

proc other(name: string; backend: manifest.BackendKind; core = "";
           operation = ""): OperationEntry =
  OperationEntry(name: name, backend: backend, delegateCore: core,
    delegateOperation: if operation.len > 0: operation else: name,
    common: CommonOptions(timeoutMs: 1000))

proc core(name: string; ops: seq[OperationEntry]; modes = {cmSystem, cmUser}): LocalCore =
  LocalCore(manifest: CoreManifest(name: name, directory: base / name, manifestVersion: 1,
      modes: modes, operations: ops, account: ""),
    dirs: CoreDirectories(root: base / name, stateDir: base / "state" / name,
      runtimeDir: base / "run" / name))

proc loaderFor(cores: seq[LocalCore]): CoreLoader =
  var table = initTable[string, LocalCore]()
  for c in cores: table[c.manifest.name] = c
  result = proc(name: string): LocalCore =
    if not table.hasKey(name): raise newCoreError(ecNotFound, "core not found: " & name, name)
    table[name]

proc failureCode(load: CoreLoader; coreName, operation: string): (CoreErrorCode, string) =
  try:
    discard resolveTarget(load, testMode, coreName, operation)
    (ecUsage, "resolved")
  except CoreError as e: (e.code, e.msg)

suite "resolving the operation to run":
  test "delegation is followed, counted, and may reach a core that is not enabled":
    let load = loaderFor(@[
      core("front", @[other("service.start", manifest.bkDelegate, "back")]),
      core("back", @[other("service.start", manifest.bkDelegate, "tail", "service.restart")]),
      core("tail", @[exec("service.restart", "5s", manifest.emOneshot)])])
    let target = resolveTarget(load, testMode, "front", "service.start")
    check target.core == "tail" and target.operation == "service.restart"
    check target.hops == 2
    check target.mutating
    check target.op.executable == "bin/adapter"

  test "unsupported and absent entries are E_UNSUPPORTED, never a fallback":
    let load = loaderFor(@[core("c", @[other("service.stop", manifest.bkUnsupported)])])
    check failureCode(load, "c", "service.stop")[0] == ecUnsupported
    check failureCode(load, "c", "mount.status")[0] == ecUnsupported
    check failureCode(load, "c", "unit.list")[0] == ecUnsupported
    check failureCode(load, "nowhere", "unit.list")[0] == ecNotFound

  test "native entries and serviceHandler need the daemon":
    let load = loaderFor(@[core("c", @[other("service.stop", manifest.bkNative)])])
    let (code, message) = failureCode(load, "c", "service.stop")
    check code == ecUnsupported and message == NativeUnsupported
    check failureCode(load, "serviceHandler", "service.start") == (ecUnsupported, NativeUnsupported)
    check failureCode(load, "serviceHandler", "core.verify") ==
      (ecUnsupported, "serviceHandler does not claim core")
    let delegating = loaderFor(@[core("d", @[other("service.stop", manifest.bkDelegate, "serviceHandler")])])
    check failureCode(delegating, "d", "service.stop") == (ecUnsupported, NativeUnsupported)

  test "cycles and chains of more than four hops are E_DELEGATION (§13.4)":
    var cores: seq[LocalCore]
    for i in 1 .. 6:
      cores.add core("h" & $i, @[other("unit.list",
        if i == 6: manifest.bkExec else: manifest.bkDelegate, "h" & $(i + 1))])
      if i == 6:
        cores[^1].manifest.operations[0] = exec("unit.list", "5s")
    cores.add core("cyc1", @[other("unit.list", manifest.bkDelegate, "cyc2")])
    cores.add core("cyc2", @[other("unit.list", manifest.bkDelegate, "cyc1")])
    cores.add core("lost", @[other("unit.list", manifest.bkDelegate, "gone")])
    cores.add core("narrow", @[other("unit.list", manifest.bkDelegate, "h6", "unit.list")])
    cores.add core("empty", @[exec("unit.resolve", "5s")])
    cores.add core("toempty", @[other("unit.list", manifest.bkDelegate, "empty")])
    let load = loaderFor(cores)
    check resolveTarget(load, testMode, "h2", "unit.list").hops == 4
    check failureCode(load, "h1", "unit.list") == (ecDelegation, "delegation chain exceeds four hops")
    check failureCode(load, "cyc1", "unit.list") == (ecDelegation, "delegation cycle")
    let lost = failureCode(load, "lost", "unit.list")
    check lost[0] == ecDelegation and "core is unavailable: gone" in lost[1]
    check failureCode(load, "toempty", "unit.list")[0] == ecDelegation

  test "a core that does not support the mode is E_UNSUPPORTED":
    let other = if testMode == cmSystem: cmUser else: cmSystem
    let load = loaderFor(@[core("c", @[exec("unit.list", "5s")], {other})])
    check failureCode(load, "c", "unit.list")[0] == ecUnsupported

  test "mutating follows the registry class of the typed or the executed operation":
    let load = loaderFor(@[core("c", @[exec("unit.list", "5s"), exec("service.status", "5s"),
      exec("service.start", "5s"), exec("log.follow", "5s"),
      other("service.reload", manifest.bkDelegate, "c", "service.status")])])
    for (op, mutating) in [("unit.list", false), ("service.status", false),
                           ("service.start", true), ("log.follow", false),
                           ("service.reload", true)]:
      check resolveTarget(load, testMode, "c", op).mutating == mutating
    check isMutating("unit.load") and isMutating("log.write") and not isMutating("core.verify")
    check operationIsStreaming("log.follow") and not operationIsStreaming("log.read")

suite "running one operation with a real adapter":
  createDir(base)
  discard chmod(base.cstring, Mode(0o755))
  let pidFile = base / "pid"
  let ops = "unit.list,service.status,log.follow"
  let env = @[("TEST_OPS", ops), ("TEST_PID_FILE", pidFile)]
  let root = base / "demo"
  for dir in [root, root / "bin", base / "state", base / "run"]:
    createDir(dir)
    discard chmod(dir.cstring, Mode(0o755))
  writeFile(root / "bin" / "adapter", AdapterSource)
  discard chmod(cstring(root / "bin" / "adapter"), Mode(0o755))
  let demo = core("demo", @[exec("unit.list", "10s", env = env),
    exec("service.status", "1s", env = env), exec("log.follow", "10s", env = env)])
  let load = loaderFor(@[demo])
  var config = RuntimeConfig(mode: testMode, jumpstartVersion: "1.3.0",
    trustedUid: getuid(), runnerTrustedUid: Uid(0))
  if testMode == cmUser: config.identity = userIdentityFor(getuid())

  proc adapterGone(): bool =
    let pid = parseInt(readFile(pidFile).strip)
    kill(Pid(pid), 0) != 0

  test "items stream through the hook, the result keeps all of them, and the adapter ends":
    var seen: seq[string]
    var hooks = LocalRunHooks()
    hooks.onItem = proc(operation, field: string; item: JsonNode) =
      seen.add operation & "/" & field & "/" & item["name"].getStr
    let outcome = runLocal(load, config, "demo", "unit.list", "", newJObject(), hooks)
    check seen == @["unit.list/units/a", "unit.list/units/b"]
    check outcome.streamed == {"units": 2}.toTable
    check outcome.value["units"].len == 3
    check outcome.value["units"][2]["name"].getStr == "c"
    check outcome.core == "demo" and outcome.operation == "unit.list"
    # §17.6: the persistent adapter was closed when the run ended.
    check adapterGone()

  test "the unit reaches the adapter exactly as typed":
    let outcome = runLocal(load, config, "demo", "service.status", "Mixed@Case.Service",
      newJObject())
    check outcome.value["detail"].getStr == "Mixed@Case.Service"
    check outcome.streamed.len == 0

  test "an invalid result is E_PROTOCOL; an invalid item is never printed":
    try:
      discard runLocal(load, config, "demo", "service.status", "bogus", newJObject())
      check false
    except CoreError as e:
      check e.code == ecProtocol
    var printed = 0
    var hooks = LocalRunHooks()
    hooks.onItem = proc(operation, field: string; item: JsonNode) = inc printed
    try:
      discard runLocal(load, config, "demo", "service.status", "badevent", newJObject(), hooks)
      check false
    except CoreError as e:
      check e.code == ecProtocol
    check printed == 0

  test "the operation's timeout is an absolute deadline (E_TIMEOUT)":
    let started = epochTime()
    try:
      discard runLocal(load, config, "demo", "service.status", "hang", newJObject())
      check false
    except CoreError as e:
      check e.code == ecTimeout
    check epochTime() - started < 10
    check adapterGone()

  test "the interrupted hook cancels the request (E_CANCELLED)":
    var polls = 0
    var entries: seq[string]
    var hooks = LocalRunHooks()
    hooks.interrupted = proc(): bool =
      inc polls
      polls > 5
    hooks.onEntry = proc(entry: JsonNode) = entries.add entry["message"].getStr
    try:
      discard runLocal(load, config, "demo", "log.follow", "u", newJObject(), hooks)
      check false
    except CoreError as e:
      check e.code == ecCancelled
    check entries == @["one"]
    check adapterGone()

  test "a missing runtime directory exists for the run only; an existing one is left alone":
    let runtimeDir = base / "run" / "demo"
    removeDir(runtimeDir)
    let first = runLocal(load, config, "demo", "service.status", "rtdir", newJObject())
    check first.value["detail"].getStr == "0o700"
    check not dirExists(runtimeDir)                 # removed again afterwards
    createDir(runtimeDir)
    writeFile(runtimeDir / "daemon-state", "kept")
    discard runLocal(load, config, "demo", "service.status", "rtdir", newJObject())
    check readFile(runtimeDir / "daemon-state") == "kept"   # a loaded core's directory
    removeDir(runtimeDir)

  test "a directory that a daemon created in the meantime is not removed":
    let runtimeDir = base / "run" / "other"
    removeDir(runtimeDir)
    let transient = ensureRuntimeDir(runtimeDir, testMode, "")
    check dirExists(runtimeDir)
    # Keep the old directory alive so the replacement cannot reuse its inode.
    moveDir(runtimeDir, runtimeDir & ".old")
    createDir(runtimeDir)                           # the daemon's fresh directory
    writeFile(runtimeDir / "live", "x")
    transient.release()
    check fileExists(runtimeDir / "live")
    removeDir(runtimeDir)
    removeDir(runtimeDir & ".old")

  test "beforeRun sees the resolved target before anything starts":
    var announced = ""
    discard runLocal(load, config, "demo", "service.status", "x", newJObject(),
      beforeRun = proc(target: LocalTarget) = announced = target.core & ":" & target.operation)
    check announced == "demo:service.status"
    var ran = false
    try:
      discard runLocal(load, config, "demo", "mount.status", "x", newJObject(),
        beforeRun = proc(target: LocalTarget) = ran = true)
    except CoreError as e:
      check e.code == ecUnsupported
    check not ran

removeDir(base)
