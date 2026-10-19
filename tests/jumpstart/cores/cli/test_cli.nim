import std/[json, options, strutils, tables, unittest]
import ../../../../jumpstart/cores/cli/cli,
  ../../../../jumpstart/cores/daemon/control,
  ../../../../jumpstart/cores/manifest/modes
import jumpstartcore/errors

proc cmd(kind: CliCommandKind): CliCommand = command(kind)

suite "argument-independent jumpctl command model":
  test "classification covers local, live, and ordered mixed commands":
    for kind in [ccCoresShow, ccCoresCheck, ccCoresRun, ccUsersLingerList,
                 ccUsersLingerEnable, ccUsersLingerDisable]:
      check cmd(kind).execution == ceLocal
      check not cmd(kind).usesDaemon
    var listing = cmd(ccCoresList)
    check listing.isLocal
    listing.loadedOnly = true
    check listing.execution == ceLive
    for kind in [ccCoresEnable, ccCoresDisable]:
      var change = cmd(kind)
      check change.execution == ceLocal
      change.now = true
      check change.execution == ceLiveThenLocal
      check change.persistsAfterLive
    check cmd(ccStart).execution == ceLive

  test "mode-specific commands are rejected before any I/O":
    for kind in [ccPoweroff, ccReboot, ccHalt, ccUsersList,
                 ccUsersLingerList, ccUsersLingerEnable]:
      check allowedInMode(kind, cmSystem)
      check not allowedInMode(kind, cmUser)
      expect CoreError: cmd(kind).validateMode(cmUser)
    for kind in [ccEnvList, ccEnvSet, ccEnvUnset, ccEnvImport]:
      check allowedInMode(kind, cmUser)
      check not allowedInMode(kind, cmSystem)
      expect CoreError: cmd(kind).validateMode(cmSystem)
    check allowedInMode(ccStart, cmSystem)
    check allowedInMode(ccStart, cmUser)

  test "unit requests preserve opaque names and construct exact arguments":
    var start = cmd(ccStart); start.unit = "systemd/sshd.service"
    let request = start.buildRequest("1.3.0")
    check request.kind == rkService
    check request.client == ClientInfo(name: "Jumpstart CLI", version: "1.3.0")
    check request.service.name == "systemd/sshd.service"
    check request.service.action == "start"
    check request.service.args == newJObject()

    var enable = cmd(ccEnable)
    enable.unit = "opaque@name.service"; enable.now = true; enable.target = "multi-user.target"
    let enabled = enable.buildRequest("test")
    check enabled.service.now == some("true")
    check enabled.service.args == %* {"now": true, "target": "multi-user.target"}

    var kill = cmd(ccKill); kill.unit = "worker"
    check kill.buildRequest("test").service.args == %* {"signal": "SIGTERM"}
    kill.signal = "HUP"
    check kill.buildRequest("test").service.args["signal"].getStr == "HUP"

  test "log requests route by unit or explicit core":
    var read = cmd(ccLogsRead); read.unit = "web"; read.lines = 42; read.since = "2026-01-01T00:00:00Z"
    let byUnit = read.buildRequest("test")
    check byUnit.kind == rkService
    check byUnit.service.action == "log-read"
    check byUnit.service.args["lines"].getInt == 42
    check byUnit.service.args["since"].getStr == read.since
    read.unit = ""; read.core = "systemd"
    let byCore = read.buildRequest("test")
    check byCore.kind == rkOp
    check byCore.op.name == "log.read"
    check byCore.op.core == "systemd"
    read.lines = 10001
    expect CoreError: discard read.buildRequest("test")

  test "lifecycle, power and user requests are exact":
    var unload = cmd(ccCoresUnload); unload.core = "openrc"; unload.stopUnits = true
    let coreReq = unload.buildRequest("v")
    check coreReq.kind == rkCore
    check coreReq.core.name == some("openrc")
    check coreReq.core.action == "unload"
    check coreReq.core.stopUnits == some(true)
    check cmd(ccPoweroff).buildRequest("v").power.action == "poweroff"
    check cmd(ccUsersList).buildRequest("v").users.action == "list"

  test "local commands cannot accidentally produce socket requests":
    for kind in [ccCoresShow, ccCoresCheck, ccCoresRun, ccUsersLingerList]:
      expect CoreError: discard cmd(kind).buildRequest("v")

  test "fan-out requests name one core; environment requests are string maps":
    expect CoreError: discard cmd(ccGetDefault).buildRequest("v")
    var listing = cmd(ccUnitsList); listing.core = "systemd"
    check listing.buildRequest("v").op == OpRequest(core: "systemd", name: "unit.list", args: newJObject())
    let loaded = cmd(ccCoresListLoaded).buildRequest("v")
    check loaded.core.action == "list-loaded"
    check loaded.core.name.isNone
    var set = cmd(ccEnvSet); set.values = @["DISPLAY=:0", "EMPTY="]
    check set.buildRequest("v").env.vars == %* {"DISPLAY": ":0", "EMPTY": ""}
    check set.buildRequest("v").env.action == "set"
    var imported = cmd(ccEnvImport); imported.values = @["DISPLAY=:1"]
    check imported.buildRequest("v").env == EnvRequest(action: "set", vars: %*{"DISPLAY": ":1"})
    var unset = cmd(ccEnvUnset); unset.keys = @["DISPLAY"]
    check unset.buildRequest("v").env == EnvRequest(action: "unset", vars: %*{"DISPLAY": ""})
    for bad in [@["BROKEN"], @["HOME=/x"], @["JUMPSTART_X=1"], @["lower=1"]]:
      set.values = bad
      expect CoreError: discard set.buildRequest("v")

suite "exact jumpctl presentation":
  test "compatibility unit lines use names exactly as typed":
    let cases = [
      (ccStart, "jumpstart: started unit raw.name\n"),
      (ccStop, "jumpstart: stopped unit raw.name\n"),
      (ccRestart, "jumpstart: restarted unit raw.name\n"),
      (ccReload, "jumpstart: reloaded unit raw.name\n"),
      (ccKill, "jumpstart: killed unit raw.name\n"),
      (ccEnable, "jumpstart: enabled unit raw.name\n"),
      (ccDisable, "jumpstart: disabled unit raw.name\n"),
      (ccIsolate, "jumpstart: isolated unit raw.name\n")]
    for item in cases:
      var command = cmd(item[0]); command.unit = "raw.name"
      check command.formatSuccess == item[1]
    var status = cmd(ccStatus); status.unit = "raw.name"
    check status.formatSuccess(%* {"state": "active"}) ==
      "jumpstart: unit is reporting status as 'active'\n"

  test "core and power success lines are exact":
    var core = cmd(ccCoresLoad); core.core = "systemd"
    check core.formatSuccess == "jumpctl: loaded core systemd\n"
    core.kind = ccCoresUnload
    check core.formatSuccess == "jumpctl: unloaded core systemd\n"
    core.kind = ccCoresReload
    check core.formatSuccess == "jumpctl: reloaded core systemd\n"
    check cmd(ccPoweroff).formatSuccess == "jumpctl: powering off\n"
    check cmd(ccReboot).formatSuccess == "jumpctl: rebooting\n"
    check cmd(ccHalt).formatSuccess == "jumpctl: halting\n"

  test "plain data is unadorned, ordered, and empty means empty":
    check cmd(ccCoresList).formatSuccess(%* {"cores": [
      {"name": "serviceHandler", "state": "loaded"}, {"name": "x", "state": "unloaded"},
      {"name": "systemd", "state": "degraded", "stale": true}]}) == "serviceHandler\nsystemd\n"
    check cmd(ccCoresList).formatSuccess(%* {"cores": []}) == ""
    var run = cmd(ccCoresRun); run.operation = "core.verify"
    check run.formatSuccess(%* {"version": "255", "installed": true}) ==
      "installed: true\nversion: 255\n"
    check formatCoresStatus(%*{"cores": [{"name": "a", "state": "failed",
      "error": {"code": "E_INIT", "message": "boom"}}, {"name": "b", "state": "loaded", "stale": true}]}) ==
      "a failed E_INIT: boom\nb loaded stale\n"
    expect CoreError: discard formatCoresStatus(%*{"cores": [{"name": "a", "state": "sleeping"}]})
    check formatUnitRows("c", %*{"units": [{"name": "u", "subsystem": "service", "enablement": "masked"}]}) ==
      "c/u service masked\n"
    expect CoreError: discard formatUnitRows("c", %*{"units": [{"name": "u"}]})
    expect CoreError: discard formatUnitsLoad("c", %*{"errors": []})
    check formatLogEntry(%*{"time": "T", "level": "info", "unit": "", "message": "m"}) == "T info - m\n"
    check formatCoreObject(%*{"line": 3, "message": "x", "name": "n"}) == "n: x line=3"
    check formatUsers(%*{"users": [{"uid": 5, "user": "u", "sessions": 1, "state": "failed",
      "linger": false}]}) == "5 u 1 failed -\n"
    check formatEnvironment(%*{"vars": {"B": "2", "A": "1"}}) == "A=1\nB=2\n"

  test "the reply stream merges items before the response's own elements":
    var collector = ReplyCollector()
    collector.add parseStreamLine("""{"type":"event","event":"item","field":"units","data":{"name":"a","subsystem":"service","enablement":"enabled"}}""")
    let entryLine = parseStreamLine("""{"type":"event","event":"entry","data":{"time":"t","level":"info","unit":"u","message":"m"}}""")
    check entryLine.kind == skEntry
    let response = parseStreamLine("""{"type":"response","status":"ok","result":{"units":[{"name":"b","subsystem":"service","enablement":"static"}]},"warnings":[],"core":"x"}""")
    check response.kind == skResponse
    check response.reply.core == "x"
    let merged = collector.merged(response.reply)
    check merged["units"][0]["name"].getStr == "a"
    check merged["units"][1]["name"].getStr == "b"
    let failure = parseStreamLine("""{"type":"response","status":"error","error":{"code":"E_BUSY","message":"m","core":"c"}}""")
    check not failure.reply.ok
    check failure.reply.code == ecBusy
    check failure.reply.core == "c"
    for bad in ["not json", "[]", """{"type":"other"}""", """{"type":"response","status":"error","error":{"code":"E_NOPE","message":"m"}}""",
                """{"type":"event","event":"mystery","data":{}}"""]:
      expect CoreError: discard parseStreamLine(bad)

  test "native status uses the native text and extension status the state":
    check formatStatus(%*{"state": "inactive", "detail": "stopped with an exit code 1"}, "serviceHandler") ==
      "jumpstart: unit is reporting status as 'stopped with an exit code 1'\n"
    check formatStatus(%*{"state": "active", "detail": "running"}, "systemd") ==
      "jumpstart: unit is reporting status as 'active'\n"

  test "extension status appends since, substate and result in that order (§21.2)":
    let full = %*{"state": "reloading", "detail": "x", "enablement": "enabled",
      "result": "success", "substate": "reload", "since": "2026-10-17T12:00:00Z"}
    check formatStatus(full, "systemd") ==
      "jumpstart: unit is reporting status as 'reloading'\n" &
      "since: 2026-10-17T12:00:00Z\nsubstate: reload\nresult: success\n"
    check formatStatus(%*{"state": "active", "substate": "running"}, "systemd") ==
      "jumpstart: unit is reporting status as 'active'\nsubstate: running\n"
    check formatStatus(%*{"state": "failed", "result": "exit-code"}, "systemd") ==
      "jumpstart: unit is reporting status as 'failed'\nresult: exit-code\n"
    # Native output never changes, even for a hostile or odd result.
    check formatStatus(%*{"state": "active", "detail": "running", "since": "x"},
      "serviceHandler") == "jumpstart: unit is reporting status as 'running'\n"
    # Through the whole reply path (validated like any extension result).
    var status = cmd(ccStatus); status.unit = "systemd/-.mount"
    let reply = Reply(ok: true, core: "systemd", result: %*{"state": "active",
      "detail": "", "enablement": "static", "source": "/dev/sda1", "target": "/",
      "fstype": "ext4", "since": "2026-10-17T12:00:00Z", "substate": "mounted"})
    check formatReply(status, reply).stdout ==
      "jumpstart: unit is reporting status as 'active'\n" &
      "since: 2026-10-17T12:00:00Z\nsubstate: mounted\n"
    var setDefault = cmd(ccSetDefault); setDefault.unit = "systemd/multi-user.target"
    check setDefault.formatSuccess(newJObject(), "systemd") ==
      "jumpstart: default target of systemd is now multi-user.target\n"
    check formatReply(setDefault, Reply(ok: true, result: newJObject())).stdout ==
      "jumpstart: default target of systemd is now multi-user.target\n"
    setDefault.unit = "multi-user.target"
    check formatReply(setDefault, Reply(ok: true, result: newJObject())).exitStatus == 1

  test "cores run arguments follow the registry types":
    expect CoreError: discard convertArgument("core.verify", "x", "1")
    check convertArgument("log.read", "lines", "5") == %5
    check convertArgument("service.enable", "now", "true") == %true
    expect CoreError: discard convertArgument("log.read", "lines", "five")

  test "all error categories map to exact diagnostics and statuses":
    for code in CoreErrorCode:
      let rendered = formatError(code, "failed", if code == ecBackend: "systemd" else: "")
      check rendered.exitStatus == exitCode(code)
      if code == ecBackend:
        check rendered.stderr == "jumpctl: systemd: E_BACKEND: failed\n"
      else:
        check rendered.stderr == "jumpctl: " & errorName(code) & ": failed\n"
      check rendered.stdout == ""
    check formatError(ecIo, "one\ntwo\rthree").stderr ==
      "jumpctl: E_IO: one two three\n"

  test "responses emit success only after ok and preserve warnings":
    var start = cmd(ccStart); start.unit = "sshd"
    let ok = formatResponse(start, okResponse(%* {}, @["old\ncore"]))
    check ok.exitStatus == 0
    check ok.stdout == "jumpstart: started unit sshd\n"
    check ok.stderr == "jumpctl: warning: old core\n"
    let failed = formatResponse(start, errorResponse(ecUnsupported, "no restart"), "openrc")
    check failed.stdout == ""
    check failed.stderr == "jumpctl: openrc: E_UNSUPPORTED: no restart\n"
    check failed.exitStatus == 3

suite "cores run arguments and output (§21.15)":
  proc usageError(args: seq[string]): string =
    try:
      discard parseRunArguments(args)
      "none"
    except CoreError as e:
      check e.code == ecUsage
      e.msg

  test "core and global operations take no UNIT":
    let verify = parseRunArguments(@["demo", "core.verify"])
    check verify.core == "demo" and verify.operation == "core.verify"
    check verify.unit == "" and verify.args == newJObject() and verify.known
    check "takes no UNIT" in usageError(@["demo", "core.verify", "sshd"])
    check "takes no UNIT" in usageError(@["demo", "unit.list", "sshd"])
    check "takes no UNIT" in usageError(@["demo", "target.get-default", "x"])
    let list = parseRunArguments(@["demo", "unit.list", "subsystem=mount"])
    check list.unit == "" and list.args == %*{"subsystem": "mount"}

  test "unit operations require a UNIT that contains no '='":
    let status = parseRunArguments(@["demo", "service.status", "sshd.service"])
    check status.unit == "sshd.service" and status.args == newJObject()
    check "requires a UNIT" in usageError(@["demo", "service.status"])
    # The first argument with '=' is a KEY=VALUE, never the UNIT.
    check "requires a UNIT" in usageError(@["demo", "service.enable", "now=true"])
    let enable = parseRunArguments(@["demo", "service.enable", "a.service", "now=true", "target=b"])
    check enable.unit == "a.service"
    check enable.args == %*{"now": true, "target": "b"}

  test "log operations take an optional UNIT":
    let global = parseRunArguments(@["demo", "log.read", "lines=5"])
    check global.unit == "" and global.args == %*{"lines": 5}
    let unit = parseRunArguments(@["demo", "log.read", "sshd", "lines=5"])
    check unit.unit == "sshd" and unit.args == %*{"lines": 5}
    check parseRunArguments(@["demo", "log.follow"]).unit == ""
    check parseRunArguments(@["demo", "log.follow", "sshd"]).unit == "sshd"

  test "UNIT is kept exactly as typed and CORE/UNIT is rejected":
    check parseRunArguments(@["demo", "service.start", "Getty@TTY1.Service"]).unit ==
      "Getty@TTY1.Service"
    check "not CORE/UNIT" in usageError(@["demo", "service.start", "demo/sshd"])
    check "not CORE/UNIT" in usageError(@["demo", "log.read", "demo/sshd"])
    check "invalid unit name" in usageError(@["demo", "service.start", "a\tb"])
    check "CORE must be a core name" in usageError(@["a/b", "core.verify"])

  test "KEY=VALUE arguments follow the registry and are checked":
    check "duplicate argument" in usageError(@["demo", "service.kill", "u", "signal=1", "signal=2"])
    check "expected KEY=VALUE" in usageError(@["demo", "service.kill", "u", "signal=1", "extra"])
    check "unknown argument" in usageError(@["demo", "service.kill", "u", "bogus=1"])
    check "unknown argument" in usageError(@["demo", "core.verify", "extra=1"])
    check "must be an integer" in usageError(@["demo", "log.read", "lines=x"])
    check parseRunArguments(@["demo", "service.kill", "u", "signal=a=b"]).args ==
      %*{"signal": "a=b"}

  test "missing and malformed operands are usage errors":
    check "expected CORE OPERATION" in usageError(@[])
    check "expected CORE OPERATION" in usageError(@["demo"])
    check "invalid operation name" in usageError(@["demo", "verify"])
    check "invalid operation name" in usageError(@["demo", "A.b"])

  test "operations outside the registry parse no further (E_UNSUPPORTED comes later)":
    let unknown = parseRunArguments(@["demo", "core.bogus", "whatever", "x=1"])
    check not unknown.known
    check unknown.unit == "" and unknown.args == newJObject()

  test "unit use follows the registry routing column":
    check unitUse("core.verify") == uuNone
    check unitUse("unit.list") == uuNone
    check unitUse("target.get-default") == uuNone
    check unitUse("log.rotate") == uuNone
    check unitUse("service.status") == uuRequired
    check unitUse("target.isolate") == uuRequired
    check unitUse("log.write") == uuOptional
    check unitUse("log.follow") == uuOptional

  test "the warning is printed for mutating operations only":
    check runWarning("service.start") == "jumpctl: warning: running service.start outside the " &
      "daemon: no locking, supervision or daemon state; for debugging only\n"
    for op in ["unit.load", "unit.activate", "log.write", "target.isolate", "service.kill"]:
      check runWarning(op).len > 0
    for op in ["core.verify", "unit.list", "unit.resolve", "service.status", "log.read",
               "log.follow", "target.get-default", "unit.validate", "unit.translate", "no.such"]:
      check runWarning(op) == ""

  test "streamed items and entries use the normal command line formats":
    check formatLocalItem("units", %*{"name": "sshd", "subsystem": "service",
      "enablement": "enabled"}) == "sshd service enabled\n"
    check formatLocalItem("entries", %*{"time": "T", "level": "info", "unit": "", "message": "m"}) ==
      "T info - m\n"
    check formatLocalItem("entries", %*{"time": "T", "level": "warn", "unit": "u", "message": "a\nb"}) ==
      "T warn u a b\n"
    check formatLocalItem("errors", %*{"name": "n", "code": "E_X", "message": "bad"}) ==
      "errors: n: E_X: bad\n"
    check formatLocalItem("diagnostics", %*{"message": "m", "line": 3}) == "diagnostics: m line=3\n"
    expect CoreError: discard formatLocalItem("units", %*{"name": "x"})
    expect CoreError: discard formatLocalItem("entries", %*{"time": "T"})

  test "results skip what was already streamed":
    let units = %*{"units": [
      {"name": "a", "subsystem": "service", "enablement": "enabled"},
      {"name": "b", "subsystem": "service", "enablement": "static"},
      {"name": "c", "subsystem": "service", "enablement": "masked"}]}
    check formatLocalResult("unit.list", units) ==
      "a service enabled\nb service static\nc service masked\n"
    check formatLocalResult("unit.list", units, {"units": 2}.toTable) == "c service masked\n"
    check formatLocalResult("unit.list", units, {"units": 3}.toTable) == ""
    check formatLocalResult("unit.load", %*{"loaded": 2, "errors": [
      {"name": "x", "message": "bad"}]}) == "loaded: 2\nerrors: x: bad\n"
    check formatLocalResult("service.status", %*{"state": "active", "detail": "up",
      "enablement": "enabled", "main_pid": 7, "pids": [7, 8]}) ==
      "state: active\ndetail: up\nenablement: enabled\nmain_pid: 7\npids: 7, 8\n"
    check formatLocalResult("log.follow", newJObject()) == ""

  test "core.verify output is unchanged":
    let verified = %*{"version": "255", "installed": true}
    check formatLocalResult("core.verify", verified) == "installed: true\nversion: 255\n"
    check formatLocalResult("core.verify", verified) == formatRunResult("core.verify", verified)
