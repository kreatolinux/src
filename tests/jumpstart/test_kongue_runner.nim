import std/[json, options, os, osproc, posix, sequtils, strutils, tables, times, unittest]
import ../../jumpstart/kongue_runner
import ../../jumpstart/cores/backends/[adapter_runtime, backend_runtime],
  ../../jumpstart/cores/manifest/[manifest, modes]
import jumpstartcore/[environment, errors, protocol, reaper, registry_types, spawn]

const Header = """manifest_version: 1
name: "demo"
core_version: "1"
version: "7"
"""
const Deadline = "2026-10-16T12:00:30Z"

proc inputsFor(request: ProtocolMessage): RunnerInputs =
  RunnerInputs(name: "demo", root: getCurrentDir(), stateDir: "/var/lib/jumpstart/cores/demo",
    runtimeDir: "/run/jumpstart/cores/demo", mode: "system", operation: request.op,
    unit: request.unit, requestId: request.id)

let offer = helloOffer(crRunner, "demo", "system", "1.3.0")

proc run(op, unit, function, body: string; args = newJObject();
         sink: MessageSink = nil): seq[ProtocolMessage] =
  let req = request("r1", op, unit, args, Deadline, function)
  runRequest(offer, req, Header & body, inputsFor(req), sink).messages

proc failureCode(op, unit, function, body: string; args = newJObject()): string =
  try:
    discard run(op, unit, function, body, args)
    "none"
  except RunnerFailure as e:
    e.code

proc response(messages: seq[ProtocolMessage]): ProtocolMessage =
  check messages.len > 0
  check messages[^1].kind == pmResponseOk
  messages[^1]

suite "Kongue runner helpers":
  test "bounded protocol framing handles fragmented input":
    var buffer = ""
    check protocolLine(buffer, "{\"type\":").isNone
    let line = protocolLine(buffer, "\"x\"}\nnext")
    check line.get == "{\"type\":\"x\"}\n"
    check buffer == "next"
    expect RunnerFailure:
      var oversized = ""
      discard protocolLine(oversized, repeat('x', 9), 8)

  test "typed scalar conversion is strict (§16.3)":
    check scalarValue(vkBool, "true").getBool
    check scalarValue(vkInt, "-42").getBiggestInt == -42
    check scalarValue(vkString, "01").getStr == "01"
    for bad in ["yes", "1", "True"]:
      expect RunnerFailure: discard scalarValue(vkBool, bad)
    for bad in ["+1", "1.0", "0x10", " 1", "", "-"]:
      expect RunnerFailure: discard scalarValue(vkInt, bad)

  test "spawn argv is not interpreted by a shell":
    let marker = getTempDir() / "kongue-runner-must-not-exist"
    if fileExists(marker): removeFile(marker)
    let result = spawnArgv("/bin/echo", @["$(touch " & marker & ")", "a; exit 9"])
    check result.exitCode == 0
    check "$(touch " in result.output
    check not fileExists(marker)

  test "spawn keeps standard error out of the captured output":
    let result = spawnArgv("/bin/sh", @["-c", "echo out; echo err >&2; exit 4"])
    check result.output == "out\n"
    check result.exitCode == 4

  test "spawn resolves bare names in PATH and reports signals":
    check spawnArgv("echo", @["hi"]).output == "hi\n"
    check spawnArgv("/bin/sh", @["-c", "kill -TERM $$"]).exitCode == 128 + SIGTERM
    expect RunnerFailure: discard spawnArgv("no-such-program-jumpstart", @[])

  test "spawned programs stay in the runner's process group (§13.7)":
    let result = spawnArgv("/bin/sh", @["-c", "ps -o pgid= -p $$"])
    check result.output.strip == $getpgrp()

  test "spawn capture limit and newline trimming":
    check trimOneNewline("a\n\n") == "a\n"
    check trimOneNewline("a\r\n") == "a"
    expect RunnerFailure:
      discard spawnArgv("/usr/bin/printf", @["12345"], limit = 4)

  test "runtime commands are rewritten only at statement start":
    let source = "func f {\n  respond state \"active\"\n  print \"respond no\"\n}\n"
    let rewritten = prepareRuntimeSource(source)
    check "macro respond state" in rewritten
    check "print \"respond no\"" in rewritten

  test "empty quoted arguments are kept":
    check splitRuntimeArgs("detail \"\"") == @["detail", ""]
    check splitRuntimeArgs("a \"x ${exec(\"b c\").output()} y\" d") ==
      @["a", "x ${exec(\"b c\").output()} y", "d"]

  test "known and unknown failure codes":
    check validFailureCode("E_TIMEOUT")
    check not validFailureCode("MADE_UP")

suite "Kongue runner requests":
  test "request execution loads manifest function and builds response":
    let messages = run("service.start", "sshd.service", "start_service",
      "func start_service {\n  respond state \"active\"\n}\n")
    check messages.len == 1
    check messages[0].result["state"].getStr == "active"

  test "core and op objects come from the §16.2 inputs":
    let messages = run("service.status", "sshd.service", "status", """
func status {
  respond state "active"
  respond detail "${core.name}|${core.version}|${core.state_dir}|${core.mode}|${core.jumpstart_version}|${op.subsystem}|${op.deadline}|${op.args.now}"
  respond enablement "enabled"
}
""", %*{"now": true})
    check messages.response.result["detail"].getStr ==
      "demo|7|/var/lib/jumpstart/cores/demo|system|1.3.0|service|" & Deadline & "|true"

  test "inputs are read from the environment and must match the protocol":
    var env = {"JUMPSTART_CORE_NAME": "demo", "JUMPSTART_CORE_ROOT": "/c",
      "JUMPSTART_CORE_STATE_DIR": "/s", "JUMPSTART_CORE_RUNTIME_DIR": "/r",
      "JUMPSTART_MODE": "system", "JUMPSTART_OP": "service.start",
      "JUMPSTART_UNIT": "a.service", "JUMPSTART_REQUEST_ID": "r1"}.toTable
    let lookup = proc(name: string): string = env.getOrDefault(name)
    let inputs = readRunnerInputs("start", lookup)
    check inputs.root == "/c" and inputs.unit == "a.service"
    # init/shutdown get no request variables.
    env.del("JUMPSTART_OP")
    check readRunnerInputs("init", lookup).operation == ""
    expect RunnerFailure: discard readRunnerInputs("start", lookup)
    env["JUMPSTART_OP"] = "service.start"
    env["JUMPSTART_CORE_STATE_DIR"] = "relative"
    expect RunnerFailure: discard readRunnerInputs("start", lookup)
    env["JUMPSTART_CORE_STATE_DIR"] = "/s"
    env["JUMPSTART_MODE"] = "both"
    expect RunnerFailure: discard readRunnerInputs("start", lookup)
    # Inputs that disagree with the hello or the request are refused.
    let req = request("r1", "service.start", "a.service", newJObject(), Deadline, "start")
    var wrong = inputsFor(req)
    wrong.unit = "b.service"
    try:
      discard runRequest(offer, req, Header & "func start {\n respond state \"active\"\n}\n", wrong)
      check false
    except RunnerFailure as e:
      check e.code == "E_PROTOCOL"

  test "respond-item streams items, checks keys and validates values":
    var seen: seq[ProtocolMessage]
    let sink: MessageSink = proc(m: ProtocolMessage) = seen.add m
    discard run("unit.list", "", "list", """
func list {
  respond-item units name=a.service subsystem=service enablement=enabled
  respond-item units "name=b c.service" subsystem=service enablement=static
}
""", sink = sink)
    check seen.mapIt(it.kind) == @[pmEventItem, pmEventItem, pmResponseOk]
    check seen[1].data["name"].getStr == "b c.service"
    check seen[1].field == "units"
    # Items are streamed; the required field itself is sent empty (§17.4).
    check seen[2].result["units"].len == 0
    check failureCode("unit.list", "", "list",
      "func list {\n respond-item units name=a subsystem=service enablement=enabled state=active\n}\n") == "E_PROTOCOL"
    check failureCode("unit.list", "", "list",
      "func list {\n respond-item units name=a subsystem=service enablement=sometimes\n}\n") == "E_PROTOCOL"
    check failureCode("unit.list", "", "list",
      "func list {\n respond-item units name=a subsystem=service\n}\n") == "E_PROTOCOL"
    check failureCode("unit.list", "", "list",
      "func list {\n respond-item nothing name=a\n}\n") == "E_PROTOCOL"

  test "respond converts to registry types and the result is validated":
    let loaded = run("unit.load", "", "load", "func load {\n respond loaded \"3\"\n}\n")
    check loaded.response.result["loaded"].getInt == 3
    let pids = run("service.status", "a.service", "status", """
func status {
  respond state "active"
  respond detail ""
  respond enablement "enabled"
  respond pids "10"
  respond pids "11"
}
""")
    check pids.response.result["pids"] == %*[10, 11]
    check pids.response.result["detail"].getStr == ""
    check failureCode("unit.load", "", "load", "func load {\n respond loaded \"three\"\n}\n") == "E_PROTOCOL"
    check failureCode("service.start", "a.service", "start", "func start {\n respond pid \"1\"\n}\n") == "E_PROTOCOL"
    check failureCode("service.start", "a.service", "start", "func start {\n print \"nothing\"\n}\n") == "E_PROTOCOL"
    check failureCode("service.start", "a.service", "start", "func start {\n respond state \"sleepy\"\n}\n") == "E_PROTOCOL"

  test "fail keeps defined codes and maps others to E_BACKEND (§16.3)":
    check failureCode("service.start", "a.service", "start",
      "func start {\n fail E_UNIT_STATE \"masked\"\n}\n") == "E_UNIT_STATE"
    check failureCode("service.start", "a.service", "start",
      "func start {\n fail E_MADE_UP \"x\"\n}\n") == "E_BACKEND"

  test "log is sent at once as a core-log entry, not into the result":
    var seen: seq[(ProtocolMessage, float)]
    let sink: MessageSink = proc(m: ProtocolMessage) = seen.add (m, epochTime())
    discard run("service.start", "a.service", "start", """
func start {
  log notice "starting"
  spawn "/bin/sleep" "0.3"
  respond state "active"
}
""", sink = sink)
    check seen.len == 2
    check seen[0][0].kind == pmEventEntry
    check seen[0][0].data["level"].getStr == "notice"
    check seen[0][0].data["message"].getStr == "starting"
    check seen[0][0].data["unit"].getStr == "a.service"
    check validDeadline(seen[0][0].data["time"].getStr)
    # Streamed: the entry left before the 0.3 s program ran.
    check seen[1][1] - seen[0][1] >= 0.25
    check failureCode("service.start", "a.service", "start",
      "func start {\n log loud \"x\"\n}\n") == "E_PROTOCOL"

  test "statement spawn fails on non-zero exit, expression forms never do":
    check failureCode("service.start", "a.service", "start",
      "func start {\n spawn \"/bin/sh\" \"-c\" \"exit 3\"\n respond state \"active\"\n}\n") == "E_BACKEND"
    let messages = run("service.status", "a.service", "status", """
func status {
  respond state "active"
  respond detail "${spawn(\"/bin/sh\", \"-c\", \"echo noise; exit 3\").exit()}"
  respond enablement "enabled"
}
""")
    check messages.response.result["detail"].getStr == "3"

  test "§16.4: request data stays one opaque argument":
    let marker = getTempDir() / ("kongue-runner-injection-" & $getpid())
    if fileExists(marker): removeFile(marker)
    let hostile = "a\", \"-x; touch " & marker & " $(touch " & marker & ") `touch " &
      marker & "` ${HOME} '\\\""
    let messages = run("service.status", "a.service", "status", """
func status {
  local copy = "${op.args.target}"
  respond state "active"
  respond detail "${spawn(\"/usr/bin/printf\", \"%s|\", \"${copy}\", \"--\").output()}"
  respond enablement "enabled"
  spawn "/usr/bin/printf" "%s" "${op.args.target}"
}
""", %*{"target": hostile})
    check messages.response.result["detail"].getStr == hostile & "|--|"
    check not fileExists(marker)

  test "§16.4: handlers cannot reach the shell, init can":
    check failureCode("service.start", "a.service", "start",
      "func start {\n exec \"true\"\n respond state \"active\"\n}\n") == "E_MANIFEST"
    let messages = run("core.verify", "", "init", """
init {
  respond greeting "${exec(\"echo hi; echo err >&2\").output()}"
  filesystems-ready
}
""")
    check messages.mapIt(it.kind) == @[pmFilesystemsReady, pmResponseOk]
    check messages[^1].result["greeting"].getStr == "hi"
    check failureCode("core.verify", "", "shutdown",
      "shutdown {\n filesystems-ready\n}\n") == "E_PROTOCOL"

# ---------------------------------------------------------------------------
# The runner as a real process, driven by the backend runtime (§16.1, §17).

const E2EManifest = Header & """
func list_units {
  log info "listing"
  print "to stdout"
  respond-item units name=a.service subsystem=service enablement=enabled
  respond-item units "name=${op.args.extra}" subsystem=service enablement=static
}
func status {
  respond state "active"
  respond detail "${core.state_dir}|${op.request_id}|${JUMPSTART_ARG_EXTRA}|${JUMPSTART_CORE}"
  respond enablement "enabled"
}
func start {
  fail E_UNIT_STATE "masked"
}
func stop {
  spawn "/bin/sleep" "30"
  respond state "inactive"
}
"""

proc buildRunner(dir: string): string =
  ## Build the runner executable, or copy a prebuilt one named by
  ## JUMPSTART_TEST_KONGUE_RUNNER (for accounts without the Nim packages).
  result = dir / "kongue-runner"
  let prebuilt = getEnv("JUMPSTART_TEST_KONGUE_RUNNER")
  if prebuilt.len > 0:
    copyFile(prebuilt, result)
    discard chmod(result.cstring, Mode(0o755))
    return
  let source = currentSourcePath.parentDir.parentDir.parentDir / "jumpstart" / "kongue_runner.nim"
  let (output, code) = execCmdEx("nim c --threads:off --hints:off --nimcache:" &
    quoteShell(dir / "cache") & " -o:" & quoteShell(result) & " " & quoteShell(source))
  if code != 0: echo output
  doAssert code == 0
  discard chmod(result.cstring, Mode(0o755))

proc customEntry(name, handler, timeout: string): OperationEntry =
  OperationEntry(name: name, backend: manifest.bkCustom, handler: handler,
    common: CommonOptions(timeoutMs: parseDuration(timeout)))

suite "kongue-runner process":
  let base = getTempDir() / ("jumpstart-kr-" & $getpid())
  if dirExists(base): removeDir(base)
  createDir(base)
  discard chmod(base.cstring, Mode(0o755))
  let runnerPath = buildRunner(base)
  let dirs = CoreDirectories(root: base / "core", stateDir: base / "state", runtimeDir: base / "run")
  for dir in [dirs.root, dirs.stateDir, dirs.runtimeDir]:
    createDir(dir); discard chmod(dir.cstring, Mode(0o755))
  writeFile(dirs.root / "init.kg", E2EManifest)
  let mode = if getuid() == 0: cmSystem else: cmUser
  var config = RuntimeConfig(mode: mode, jumpstartVersion: "1.3.0",
    trustedUid: getuid(), runnerPath: runnerPath, runnerTrustedUid: getuid())
  if mode == cmUser: config.identity = userIdentityFor(getuid())
  let runtime = newBackendRuntime(config,
    initAdapterRuntime(modeName(mode), "1.3.0", newReaper()))
  runtime.registerManifest(CoreManifest(name: "demo", directory: dirs.root,
    manifestVersion: 1, modes: {cmSystem, cmUser}, operations: @[
      customEntry("unit.list", "list_units", "20s"),
      customEntry("service.status", "status", "20s"),
      customEntry("service.start", "start", "20s"),
      customEntry("service.stop", "stop", "1s")]), dirs, "")

  test "items, log entries and output reach Jumpstart separately":
    let id = runtime.dispatch("demo", "unit.list", "", %*{"extra": "x.service"}, monotonicMs())
    let done = runtime.waitFor(id)
    check done.ok
    if not done.ok: echo done.code, " ", done.detail
    check done.value["units"].mapIt(it["name"].getStr) == @["a.service", "x.service"]
    var logs, stdoutLines: seq[string]
    while runtime.driver.hasEvents:
      let event = runtime.driver.nextEvent
      case event.kind
      of rekLog:
        check event.requestId == id
        logs.add event.level & ":" & event.text
      of rekStdout: stdoutLines.add event.text
      else: discard
    check logs == @["info:listing"]
    check "to stdout" in stdoutLines.join("\n")

  test "the runner sees the §16.2 environment and nothing invented":
    let id = runtime.dispatch("demo", "service.status", "a.service", %*{"extra": "v"},
      monotonicMs())
    let done = runtime.waitFor(id)
    check done.ok
    check done.value["detail"].getStr == dirs.stateDir & "|" & id & "|v|"

  test "fail codes are preserved end to end":
    let done = runtime.waitFor(runtime.dispatch("demo", "service.start", "a.service",
      newJObject(), monotonicMs()))
    check not done.ok
    check done.code == ecUnitState

  test "a timeout ends the runner and the programs it spawned":
    let started = epochTime()
    let done = runtime.waitFor(runtime.dispatch("demo", "service.stop", "a.service",
      newJObject(), monotonicMs()))
    check done.code == ecTimeout
    check epochTime() - started < 10
    runtime.driver.waitIdle()
    # No `sleep 30` survives the runner's process group being signalled.
    let (ps, _) = execCmdEx("ps -A -o args=")
    check not ps.splitLines.anyIt(it.strip == "/bin/sleep 30")

  test "§8.3: the runner refuses a symlinked or group-writable manifest":
    let linked = CoreDirectories(root: base / "linked", stateDir: dirs.stateDir,
      runtimeDir: dirs.runtimeDir)
    createDir(linked.root); discard chmod(linked.root.cstring, Mode(0o755))
    createSymlink(dirs.root / "init.kg", linked.root / "init.kg")
    runtime.registerManifest(CoreManifest(name: "linked", directory: linked.root,
      manifestVersion: 1, modes: {cmSystem, cmUser}, operations: @[
        customEntry("service.status", "status", "20s")]), linked, "")
    let done = runtime.waitFor(runtime.dispatch("linked", "service.status", "a.service",
      %*{"extra": "v"}, monotonicMs()))
    check not done.ok
    check done.code == ecPermission
    # A regular file that group or other can write is refused as well.
    let loose = CoreDirectories(root: base / "loose", stateDir: dirs.stateDir,
      runtimeDir: dirs.runtimeDir)
    createDir(loose.root); discard chmod(loose.root.cstring, Mode(0o755))
    writeFile(loose.root / "init.kg", E2EManifest)
    discard chmod((loose.root / "init.kg").cstring, Mode(0o666))
    runtime.registerManifest(CoreManifest(name: "loose", directory: loose.root,
      manifestVersion: 1, modes: {cmSystem, cmUser}, operations: @[
        customEntry("service.status", "status", "20s")]), loose, "")
    let looseDone = runtime.waitFor(runtime.dispatch("loose", "service.status", "a.service",
      %*{"extra": "v"}, monotonicMs()))
    check not looseDone.ok
    check looseDone.code == ecPermission

  removeDir(base)
