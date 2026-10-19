## End-to-end tests of the jumpctl binary (jumpstart-cores §27.10).
##
## jumpctl is built with -d:jumpctlTestHooks, which roots every path in a
## fixture directory and trusts the test user as the owner of core roots and
## state. A fake daemon in this process listens on the mode's control socket
## and answers each connection from a script, speaking the §14.5 protocol
## (including `event` lines). Local commands are checked to never connect.
import std/[json, os, osproc, posix, streams, strtabs, strutils, tables, times, unittest]
import std/net
import jumpstartcore/registry

const RepoRoot = currentSourcePath().parentDir.parentDir.parentDir

let fixture = getAppDir() / "jctl-fixture"
let binary = getAppDir() / "jumpctl-testhooks"

proc build(source, output: string; extra = "") =
  let cmd = quoteShell(getCurrentCompilerExe()) & " c --hints:off --threads:off --deepcopy:on " &
    extra & " -o:" & quoteShell(output) & " " & quoteShell(RepoRoot / source)
  let (text, code) = execCmdEx(cmd)
  if code != 0:
    echo text
    quit "cannot build " & source

build("jumpstart/jumpctl.nim", binary, "-d:jumpctlTestHooks")
let runner = getAppDir() / "kongue-runner-jumpctl"
build("jumpstart/kongue_runner.nim", runner)

# ---------------------------------------------------------------------------
# Fixture filesystem

const DemoManifest = """manifest_version: 1
name: "demo"
description: "Demo core"
core_version: "0.1.0"
version: "255"
jumpstart: ">=1.0.0, <3.0.0"
modes:
  - "system"
  - "user"
subsystems:
  - "core"
supported_ops:
  - name: "core.verify"
    backend: "exec"
    options:
      executable: "bin/adapter"
      mode: "oneshot"
      sandbox: true
      working_directory: "/tmp"
      timeout: "10s"
init {
  print "init"
}
func unused {
  print "never called"
}
"""

const AdapterScript = """#!/bin/sh
# A oneshot exec adapter (§17) answering core.verify.
read -r hello <&3
printf '%s\n' '{"type":"hello","protocol":"jumpstart-core/1","role":"adapter","operations":["core.verify"]}' >&4
while read -r request <&3; do
  id=$(printf '%s' "$request" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
  printf '{"type":"response","id":"%s","status":"ok","result":{"installed":true,"version":"255"}}\n' "$id" >&4
done
"""

proc writePrivate(path, content: string) =
  createDir(parentDir(path))
  writeFile(path, content)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpGroupRead, fpOthersRead})

proc tidy(path: string) =
  ## Directories 0755 so discovery accepts them (§8.3).
  for kind, entry in walkDir(path):
    if kind == pcDir:
      setFilePermissions(entry, {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead,
        fpGroupExec, fpOthersRead, fpOthersExec})
      tidy(entry)

proc resetFixture() =
  removeDir(fixture)
  for root in [fixture / "lib/cores", fixture / "home/cores"]:
    writePrivate(root / "demo/init.kg", DemoManifest)
    writePrivate(root / "demo/bin/adapter", AdapterScript)
    setFilePermissions(root / "demo/bin/adapter", {fpUserRead, fpUserWrite, fpUserExec,
      fpGroupRead, fpGroupExec, fpOthersRead, fpOthersExec})
    writePrivate(root / "broken/init.kg", "manifest_version: 1\nname: \"broken\"\n")
  removeDir(fixture / "home/cores/demo")
  removeDir(fixture / "home/cores/broken")
  createDir(fixture / "home/cores")
  writePrivate(fixture / "lib/cores/delegator/init.kg",
    DemoManifest.replace("name: \"demo\"", "name: \"delegator\"").replace(
      "    backend: \"exec\"\n    options:\n      executable: \"bin/adapter\"\n      mode: \"oneshot\"\n      sandbox: true\n      working_directory: \"/tmp\"\n      timeout: \"10s\"\n",
      "    backend: \"delegate\"\n    options:\n      core: \"demo\"\n      operation: \"core.verify\"\n").replace(
      "func unused {\n  print \"never called\"\n}\n", ""))
  createDir(fixture / "etc")
  createDir(fixture / "home/config")
  setFilePermissions(fixture, {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead,
    fpGroupExec, fpOthersRead, fpOthersExec})
  tidy(fixture)

proc socketPath(mode: string): string =
  if mode == "system": fixture / "jumpstart.sock" else: fixture / "home/data/jumpstart.sock"

proc enabledDir(mode: string): string =
  if mode == "system": fixture / "etc/cores/enabled" else: fixture / "home/config/cores/enabled"

# ---------------------------------------------------------------------------
# Fake daemon

type
  Step = object
    lines: seq[string]
    hold: bool          ## keep the connection open, interrupt jumpctl, expect EOF
  Run = object
    stdout, stderr: string
    code: int
    requests: seq[JsonNode]
    extraConnections: int
    cancelled: bool

proc ok(value: JsonNode = newJObject(); core = ""; warnings: seq[string] = @[]): string =
  var n = %*{"type": "response", "status": "ok", "result": value, "warnings": warnings}
  if core.len > 0: n["core"] = %core
  $n
proc err(code, message: string; core = ""): string =
  var e = %*{"code": code, "message": message}
  if core.len > 0: e["core"] = %core
  $(%*{"type": "response", "status": "error", "error": e})
proc item(field: string; data: JsonNode): string =
  $(%*{"type": "event", "event": "item", "field": field, "data": data})
proc entry(time, level, unit, message: string): string =
  $(%*{"type": "event", "event": "entry",
       "data": {"time": time, "level": level, "unit": unit, "message": message}})
proc step(lines: varargs[string]): Step = Step(lines: @lines)
proc rows(names: varargs[string]): JsonNode =
  result = %*{"cores": []}
  for name in names: result["cores"].add %*{"name": name, "state": "loaded"}

proc readable(fd: SocketHandle; ms: int): bool =
  var p = TPollfd(fd: cint(fd), events: POLLIN)
  posix.poll(addr p, 1, cint(ms)) > 0

proc jumpctl(args: openArray[string]; steps: seq[Step] = @[]; mode = "user";
             env: openArray[(string, string)] = []; interruptOn = ""): Run =
  let path = socketPath(mode)
  createDir(parentDir(path))
  removeFile(path)
  let listener = newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM, Protocol.IPPROTO_IP)
  listener.bindUnix(path)
  listener.listen()
  var vars = newStringTable({"JUMPCTL_TEST_ROOT": fixture, "JUMPCTL_TEST_MODE": mode,
    "PATH": getEnv("PATH")})
  for (key, value) in env: vars[key] = value
  let process = startProcess(binary, args = args, env = vars, options = {})
  if interruptOn.len > 0:
    # Ctrl-C once the fixture adapter has signalled that it is running.
    let ready = epochTime() + 30
    while epochTime() < ready and not fileExists(interruptOn) and process.running: sleep(20)
    sleep(150)
    discard posix.kill(Pid(process.processID), SIGINT)
  for s in steps:
    var accepted = false
    let deadline = epochTime() + 20
    while epochTime() < deadline:
      if readable(listener.getFd, 50):
        accepted = true
        break
      if not process.running: break
    if not accepted: break
    var client: Socket
    listener.accept(client)
    let line = client.recvLine(timeout = 5000)
    result.requests.add parseJson(line)
    for text in s.lines: client.send(text & "\n")
    if s.hold:
      sleep(300)
      discard posix.kill(Pid(process.processID), SIGINT)
      var buffer = ""
      try: result.cancelled = client.recv(buffer, 1, 5000) == 0
      except TimeoutError: result.cancelled = false
    client.close()
  result.code = process.waitForExit(30_000)
  result.stdout = process.outputStream.readAll
  result.stderr = process.errorStream.readAll
  process.close()
  while readable(listener.getFd, 0):
    var extra: Socket
    listener.accept(extra)
    extra.close()
    inc result.extraConnections
  listener.close()
  removeFile(path)

proc local(args: openArray[string]; mode = "user";
           env: openArray[(string, string)] = []; interruptOn = ""): Run =
  ## A local command: it must never connect to the socket (§27.10).
  result = jumpctl(args, mode = mode, env = env, interruptOn = interruptOn)
  check result.extraConnections == 0

# ---------------------------------------------------------------------------

resetFixture()

suite "help and usage errors":
  test "help is available at the top level and in every nested command":
    for args in [@["--help"], @[], @["help"], @["start", "--help"], @["kill", "--help"],
                 @["get-default", "--help"], @["units", "--help"], @["units", "list", "--help"],
                 @["logs", "--help"], @["logs", "follow", "--help"], @["users", "--help"],
                 @["users", "linger", "--help"], @["users", "linger", "enable", "--help"],
                 @["env", "--help"], @["env", "import", "--help"], @["cores", "--help"],
                 @["cores", "run", "--help"], @["cores", "disable", "--help"], @["poweroff", "--help"]]:
      let r = local(args)
      check r.code == 0
      check "Usage" in r.stdout
      check r.stderr == ""
    check "--stop-units" in local(["cores", "disable", "--help"]).stdout
    check "cores" in local(["--help"]).stdout

  test "unknown options and subcommands exit 2 with an E_USAGE diagnostic":
    for args in [@["start", "--bogus", "x"], @["bogus"], @["cores", "bogus"],
                 @["users", "linger", "bogus"], @["cores", "list", "extra"],
                 @["logs", "read", "--lines", "many"]]:
      let r = local(args)
      check r.code == 2
      check r.stdout == ""
      check r.stderr.startsWith("jumpctl: E_USAGE: ")
      check r.stderr.count('\n') == 1
    let r = local(["start", "--help-me"])
    check r.code == 2

  test "argument counts and option checks are usage errors before any I/O":
    for args in [@["start"], @["start", "a", "b"], @["cores", "list", "--enabled", "--loaded"],
                 @["logs", "read"], @["logs", "read", "--lines", "0"],
                 @["logs", "read", "--lines", "10001", "--core", "demo"],
                 @["logs", "read", "--since", "yesterday", "--core", "demo"],
                 @["logs", "vacuum", "--core", "demo"], @["logs", "rotate"],
                 @["logs", "write", "--core", "demo", "--level", "loud", "hi"],
                 @["enable", "x", "--target", "demo/multi"],
                 @["cores", "disable", "demo", "--stop-units"],
                 @["cores", "run", "demo", "unit.list", "x"], @["cores", "run", "demo"]]:
      let r = local(args)
      check r.code == 2
      check r.stderr.startsWith("jumpctl: E_USAGE: ")

  test "mode-specific commands in the wrong mode exit 2 without connecting":
    for args in [@["poweroff"], @["reboot"], @["halt"], @["users", "list"],
                 @["users", "linger", "list"], @["users", "linger", "enable", "nobody"]]:
      let r = local(args, mode = "user")
      check r.code == 2
      check r.stderr.startsWith("jumpctl: E_USAGE: ")
    for args in [@["env", "list"], @["env", "set", "A=b"], @["env", "unset", "A"],
                 @["env", "import", "PATH"]]:
      let r = local(args, mode = "system")
      check r.code == 2

suite "unit commands (§21.2, §21.3)":
  test "existing commands keep their output and print only after ok":
    let cases = [("start", "jumpstart: started unit sshd\n"),
      ("stop", "jumpstart: stopped unit sshd\n"),
      ("restart", "jumpstart: restarted unit sshd\n"),
      ("reload", "jumpstart: reloaded unit sshd\n"),
      ("kill", "jumpstart: killed unit sshd\n"),
      ("enable", "jumpstart: enabled unit sshd\n"),
      ("disable", "jumpstart: disabled unit sshd\n"),
      ("isolate", "jumpstart: isolated unit sshd\n")]
    for (verb, expected) in cases:
      let r = jumpctl([verb, "sshd"], @[step(ok(core = "serviceHandler"))])
      check r.code == 0
      check r.stdout == expected
      check r.stderr == ""
      check r.requests.len == 1
      check r.requests[0]["service"]["name"].getStr == "sshd"
      check r.requests[0]["service"]["action"].getStr == verb
      check r.requests[0]["client"]["name"].getStr == "Jumpstart CLI"

  test "names are passed exactly as typed, with exact arguments":
    var r = jumpctl(["kill", "systemd/getty@tty1.service"], @[step(ok())])
    check r.requests[0]["service"]["name"].getStr == "systemd/getty@tty1.service"
    check r.requests[0]["service"]["args"] == %*{"signal": "SIGTERM"}
    check r.stdout == "jumpstart: killed unit systemd/getty@tty1.service\n"
    r = jumpctl(["kill", "x", "--signal", "HUP"], @[step(ok())])
    check r.requests[0]["service"]["args"] == %*{"signal": "HUP"}
    r = jumpctl(["enable", "sshd.kg", "--now", "--target", "multi"], @[step(ok())])
    check r.requests[0]["service"]["args"] == %*{"now": true, "target": "multi"}
    check r.requests[0]["service"]["now"].getStr == "true"
    check r.stdout == "jumpstart: enabled unit sshd.kg\n"

  test "failures print a diagnostic and exit with the matching status":
    var r = jumpctl(["start", "sshd"], @[step(err("E_NOT_FOUND", "unit not found: sshd"))])
    check r.code == 1
    check r.stdout == ""
    check r.stderr == "jumpctl: E_NOT_FOUND: unit not found: sshd\n"
    r = jumpctl(["reload", "sshd"], @[step(err("E_UNSUPPORTED", "no reload", "serviceHandler"))])
    check r.code == 3
    check r.stderr == "jumpctl: serviceHandler: E_UNSUPPORTED: no reload\n"
    r = jumpctl(["stop", "systemd/sshd.service"], @[step(err("E_TIMEOUT", "timed out"))])
    check r.code == 4
    check r.stderr == "jumpctl: systemd: E_TIMEOUT: timed out\n"
    r = jumpctl(["start", "sshd"], @[step(err("E_CANCELLED", "cancelled"))])
    check r.code == 4
    r = jumpctl(["start", "sshd"], @[step(err("E_AMBIGUOUS",
      "claimed by serviceHandler/sshd, systemd/sshd.service"))])
    check r.code == 1

  test "a closed connection or missing daemon is E_IO":
    var r = jumpctl(["start", "sshd"], @[step()])
    check r.code == 1
    check r.stderr == "jumpctl: E_IO: daemon closed the connection before responding\n"
    removeFile(socketPath("user"))
    let p = startProcess(binary, args = ["status", "sshd"], env = newStringTable(
      {"JUMPCTL_TEST_ROOT": fixture, "JUMPCTL_TEST_MODE": "user"}), options = {})
    check p.waitForExit(10_000) == 1
    check p.errorStream.readAll == "jumpctl: E_IO: daemon not running\n"
    p.close()

  test "warnings go to standard error":
    let r = jumpctl(["start", "sshd"], @[step(ok(warnings = @["core openrc excluded:\nfailed"]))])
    check r.code == 0
    check r.stdout == "jumpstart: started unit sshd\n"
    check r.stderr == "jumpctl: warning: core openrc excluded: failed\n"

  test "native status output is identical to the pre-cores jumpctl":
    # HEAD printed the native status file text; the daemon now carries it.
    for text in ["running", "stopped", "mounted", "stopped with an exit code 143"]:
      let r = jumpctl(["status", "sshd"], @[step(ok(%*{"state": "inactive", "detail": text,
        "enablement": "enabled"}, core = "serviceHandler"))])
      check r.code == 0
      check r.stdout == "jumpstart: unit is reporting status as '" & text & "'\n"
    let target = jumpctl(["status", "multi"], @[step(ok(%*{"state": "activating",
      "detail": "1 of 2 members satisfied", "enablement": "static", "members": ["a", "b"]},
      core = "serviceHandler"))])
    check target.stdout == "jumpstart: unit is reporting status as 'starting'\n"
    let ext = jumpctl(["status", "systemd/sshd.service"], @[step(ok(%*{"state": "active",
      "detail": "running", "enablement": "enabled"}, core = "systemd"))])
    check ext.stdout == "jumpstart: unit is reporting status as 'active'\n"

  test "extension status appends since, substate and result; native output is unchanged":
    var r = jumpctl(["status", "systemd/sshd.service"], @[step(ok(%*{"state": "reloading",
      "detail": "sub=reload", "enablement": "enabled", "result": "success",
      "substate": "reload", "since": "2026-10-17T12:00:00Z"}, core = "systemd"))])
    check r.code == 0
    check r.stdout == "jumpstart: unit is reporting status as 'reloading'\n" &
      "since: 2026-10-17T12:00:00Z\nsubstate: reload\nresult: success\n"
    r = jumpctl(["status", "systemd/a.service"], @[step(ok(%*{"state": "active",
      "detail": "", "enablement": "enabled", "substate": "running"}, core = "systemd"))])
    check r.stdout == "jumpstart: unit is reporting status as 'active'\nsubstate: running\n"
    r = jumpctl(["status", "sshd"], @[step(ok(%*{"state": "active", "detail": "running",
      "enablement": "enabled"}, core = "serviceHandler"))])
    check r.stdout == "jumpstart: unit is reporting status as 'running'\n"

  test "set-default names the owning core from the response":
    var r = jumpctl(["set-default", "multi-user.target"], @[step(ok(core = "systemd"))])
    check r.stdout == "jumpstart: default target of systemd is now multi-user.target\n"
    check r.requests[0]["service"]["action"].getStr == "set-default"
    r = jumpctl(["set-default", "serviceHandler/graphical"], @[step(ok())])
    check r.stdout == "jumpstart: default target of serviceHandler is now graphical\n"

  test "get-default fans out over loaded cores in load order":
    var r = jumpctl(["get-default"], @[
      step(ok(rows("serviceHandler", "openrc", "systemd"))),
      step(ok(%*{"name": "default"}, core = "serviceHandler")),
      step(err("E_UNSUPPORTED", "no targets", "openrc")),
      step(ok(%*{"name": "multi-user.target"}, core = "systemd"))])
    check r.code == 0
    check r.stdout == "serviceHandler/default\nsystemd/multi-user.target\n"
    check r.requests[0]["core"]["action"].getStr == "list-loaded"
    check r.requests[1]["op"] == %*{"core": "serviceHandler", "name": "target.get-default", "args": {}}
    check r.requests[2]["op"]["core"].getStr == "openrc"
    r = jumpctl(["get-default", "--core", "systemd"],
      @[step(ok(%*{"name": "multi-user.target"}))])
    check r.requests.len == 1
    check r.stdout == "systemd/multi-user.target\n"
    r = jumpctl(["get-default", "--core", "openrc"], @[step(err("E_UNSUPPORTED", "no targets"))])
    check r.code == 3
    check r.stderr == "jumpctl: openrc: E_UNSUPPORTED: no targets\n"

suite "unit names that begin with '-' (§14.1, §21.1)":
  test "after `--` the name is passed exactly as typed, in every unit command":
    for (args, field, expected) in [
        (@["status", "--", "-.mount"], "status", "-.mount"),
        (@["start", "--", "-.slice"], "start", "-.slice"),
        (@["stop", "--", "-.mount"], "stop", "-.mount"),
        (@["restart", "--", "-.mount"], "restart", "-.mount"),
        (@["reload", "--", "-.mount"], "reload", "-.mount"),
        (@["isolate", "--", "-.mount"], "isolate", "-.mount"),
        (@["set-default", "--", "-.target"], "set-default", "-.target"),
        (@["kill", "--signal", "HUP", "--", "-.mount"], "kill", "-.mount"),
        (@["enable", "--now", "--target", "multi", "--", "-.mount"], "enable", "-.mount"),
        (@["disable", "--", "-.mount"], "disable", "-.mount"),
        (@["status", "--", "systemd/-.mount"], "status", "systemd/-.mount"),
        (@["status", "--", "--odd"], "status", "--odd")]:
      let r = jumpctl(args, @[step(ok(%*{"state": "active", "detail": "",
        "enablement": "static"}, core = "systemd"))])
      check r.code == 0
      check r.requests.len == 1
      check r.requests[0]["service"]["name"].getStr == expected
      check r.requests[0]["service"]["action"].getStr == field
    # Names are also accepted when qualified, with no `--`, because the token
    # starts with the core name.
    let q = jumpctl(["status", "systemd/-.mount"], @[step(ok(%*{"state": "active",
      "detail": "", "enablement": "static"}, core = "systemd"))])
    check q.code == 0
    check q.requests[0]["service"]["name"].getStr == "systemd/-.mount"
    check q.stdout == "jumpstart: unit is reporting status as 'active'\n"

  test "success lines print the name as typed":
    let r = jumpctl(["start", "--", "-.mount"], @[step(ok(core = "systemd"))])
    check r.stdout == "jumpstart: started unit -.mount\n"

  test "a leading-dash token before `--` is an option: E_USAGE, nothing is sent":
    for args in [@["status", "-.mount"], @["start", "-.slice"], @["kill", "-.mount", "--signal", "HUP"],
                 @["status", "-x", "--", "-.mount"], @["units", "validate", "-.mount"],
                 @["logs", "read", "-.mount"]]:
      let r = local(args)
      check r.code == 2
      check r.stdout == ""
      check r.stderr.startsWith("jumpctl: E_USAGE: ")
    # A known option is still an option, not a name.
    check local(["status", "--help"]).code == 0

  test "`--` does not lift the one-UNIT rule or hide other problems":
    for args in [@["status", "--"], @["status", "--", "-.a", "-.b"]]:
      let r = local(args)
      check r.code == 2
      check r.stderr.startsWith("jumpctl: E_USAGE: ")

  test "units, logs and cores run take a dash name after `--`":
    var r = jumpctl(["units", "validate", "--", "-.mount"],
      @[step(ok(%*{"valid": true, "diagnostics": []}))])
    check r.code == 0
    check r.requests[0]["service"]["name"].getStr == "-.mount"
    check r.requests[0]["service"]["action"].getStr == "validate"
    r = jumpctl(["units", "translate", "--", "systemd/-.mount"],
      @[step(ok(%*{"decfile": "type: mount\n"}, core = "systemd"))])
    check r.requests[0]["service"]["name"].getStr == "systemd/-.mount"
    r = jumpctl(["logs", "read", "--", "-.mount"], @[step(ok(%*{"entries": []}))])
    check r.code == 0
    check r.requests[0]["service"]["name"].getStr == "-.mount"
    check r.requests[0]["service"]["action"].getStr == "log-read"
    r = jumpctl(["logs", "write", "--level", "info", "--", "systemd/-.mount", "-hello"],
      @[step(ok())])
    check r.code == 0
    check r.requests[0]["service"]["name"].getStr == "systemd/-.mount"
    check r.requests[0]["service"]["args"]["message"].getStr == "-hello"
    # `cores run` is local: the unit is checked, never sent.
    let run = local(["cores", "run", "--", "demo", "service.status", "-.mount"])
    check "invalid unit name" notin run.stderr
    check "Unknown short option" notin run.stderr
    check local(["cores", "run", "demo", "service.status", "-.mount"]).stderr.startsWith(
      "jumpctl: E_USAGE: ")

suite "units (§21.4)":
  test "units list prints CORE/UNIT SUBSYSTEM ENABLEMENT, items first":
    let r = jumpctl(["units", "list"], @[
      step(ok(rows("serviceHandler", "plain", "systemd"))),
      step(item("units", %*{"name": "sshd", "subsystem": "service", "enablement": "enabled"}),
           ok(%*{"units": [{"name": "default", "subsystem": "target", "enablement": "static"}]})),
      step(err("E_UNSUPPORTED", "unit not claimed")),
      step(ok(%*{"units": [{"name": "getty@tty1.service", "subsystem": "service",
                            "enablement": "indirect"}]}))])
    check r.code == 0
    check r.stdout == "serviceHandler/sshd service enabled\nserviceHandler/default target static\n" &
      "systemd/getty@tty1.service service indirect\n"
    check r.requests[1]["op"]["name"].getStr == "unit.list"

  test "units list --core --subsystem sends one request":
    let r = jumpctl(["units", "list", "--core", "systemd", "--subsystem", "timer"],
      @[step(ok(%*{"units": []}))])
    check r.requests.len == 1
    check r.requests[0]["op"] == %*{"core": "systemd", "name": "unit.list", "args": {"subsystem": "timer"}}
    check r.stdout == ""
    check r.code == 0

  test "a malformed unit list is E_PROTOCOL":
    let r = jumpctl(["units", "list", "--core", "systemd"],
      @[step(ok(%*{"units": [{"name": "x", "subsystem": "service"}]}))])
    check r.code == 1
    check r.stderr.startsWith("jumpctl: systemd: E_PROTOCOL: ")

  test "units load prints CORE: loaded N and the errors":
    let r = jumpctl(["units", "load"], @[
      step(ok(rows("serviceHandler", "systemd"))),
      step(ok(%*{"loaded": 3, "errors": [{"name": "default", "code": "E_UNIT_STATE",
        "message": "reserved name"}]})),
      step(ok(%*{"loaded": 0, "errors": []}))])
    check r.stdout == "serviceHandler: loaded 3\nserviceHandler: default: E_UNIT_STATE: reserved name\n" &
      "systemd: loaded 0\n"
    let missing = jumpctl(["units", "load", "--core", "systemd"], @[step(ok(%*{"errors": []}))])
    check missing.code == 1
    check missing.stdout == ""
    check "E_PROTOCOL" in missing.stderr

  test "units validate prints diagnostics and exits 1 when invalid":
    var r = jumpctl(["units", "validate", "web"], @[step(ok(%*{"valid": true, "diagnostics": []}))])
    check r.code == 0
    check r.stdout == ""
    check r.requests[0]["service"]["action"].getStr == "validate"
    r = jumpctl(["units", "validate", "web"], @[step(item("diagnostics",
      %*{"name": "web", "code": "E_UNIT_STATE", "message": "missing exec"}),
      ok(%*{"valid": false, "diagnostics": [{"message": "bad line", "line": 4}]}))])
    check r.code == 1
    check r.stdout == "web: E_UNIT_STATE: missing exec\nbad line line=4\n"

  test "units translate prints the decfile verbatim":
    let r = jumpctl(["units", "translate", "systemd/sshd.service"],
      @[step(ok(%*{"decfile": "type: \"simple\"\nexec: \"/usr/sbin/sshd\"\n"}))])
    check r.stdout == "type: \"simple\"\nexec: \"/usr/sbin/sshd\"\n"
    check r.requests[0]["service"]["action"].getStr == "translate"

suite "logs (§21.5)":
  test "logs read prints TIME LEVEL UNIT MESSAGE":
    var r = jumpctl(["logs", "read", "sshd"], @[step(
      item("entries", %*{"time": "2026-10-17T10:00:00Z", "level": "info", "unit": "sshd",
                         "message": "started"}),
      ok(%*{"entries": [{"time": "2026-10-17T10:00:01Z", "level": "warn", "unit": "",
                         "message": "two\nlines"}]}))])
    check r.code == 0
    check r.stdout == "2026-10-17T10:00:00Z info sshd started\n2026-10-17T10:00:01Z warn - two lines\n"
    check r.requests[0]["service"] == %*{"name": "sshd", "action": "log-read", "args": {"lines": 1000}}
    r = jumpctl(["logs", "read", "--core", "systemd", "--lines", "5", "--since",
                 "2026-10-17T00:00:00Z", "--until", "2026-10-17T12:00:00+03:00"],
      @[step(ok(%*{"entries": []}))])
    check r.requests[0]["op"] == %*{"core": "systemd", "name": "log.read", "args":
      {"since": "2026-10-17T00:00:00Z", "until": "2026-10-17T12:00:00+03:00", "lines": 5}}

  test "logs follow streams entries until interrupted, closing the connection":
    var s = step(entry("2026-10-17T10:00:00Z", "info", "sshd", "one"),
                 entry("2026-10-17T10:00:01Z", "error", "sshd", "two"))
    s.hold = true
    let r = jumpctl(["logs", "follow", "sshd", "--since", "2026-10-17T00:00:00Z"], @[s])
    check r.cancelled
    check r.code == 0
    check r.stdout == "2026-10-17T10:00:00Z info sshd one\n2026-10-17T10:00:01Z error sshd two\n"
    check r.requests[0]["service"] == %*{"name": "sshd", "action": "log-follow",
      "args": {"since": "2026-10-17T00:00:00Z"}}

  test "an interrupted request is cancelled by closing the connection":
    var s = step()
    s.hold = true
    let r = jumpctl(["start", "slow"], @[s])
    check r.cancelled
    check r.code == 4
    check r.stdout == ""
    check r.stderr == "jumpctl: E_CANCELLED: interrupted\n"

  test "write, rotate, and vacuum":
    var r = jumpctl(["logs", "write", "sshd", "--level", "notice", "hello world"], @[step(ok())])
    check r.stdout == "jumpctl: wrote log entry\n"
    check r.requests[0]["service"]["args"] == %*{"level": "notice", "message": "hello world"}
    r = jumpctl(["logs", "write", "--core", "systemd", "--level", "info", "msg"], @[step(ok())])
    check r.requests[0]["op"]["name"].getStr == "log.write"
    r = jumpctl(["logs", "rotate", "--core", "systemd"], @[step(ok())])
    check r.stdout == "jumpctl: rotated logs of core systemd\n"
    r = jumpctl(["logs", "vacuum", "--core", "systemd", "--max-size", "1024", "--max-age", "7d"],
      @[step(ok(%*{"freed": 512}))])
    check r.requests[0]["op"]["args"] == %*{"max_size": 1024, "max_age": "7d"}
    check r.stdout == "jumpctl: vacuumed logs of core systemd, freed 512 bytes\n"

suite "power, users, and env (§21.6, §21.8, §21.9)":
  test "power commands print once the daemon confirms":
    for (verb, text) in [("poweroff", "jumpctl: powering off\n"), ("reboot", "jumpctl: rebooting\n"),
                         ("halt", "jumpctl: halting\n")]:
      let r = jumpctl([verb], @[step(ok())], mode = "system")
      check r.stdout == text
      check r.requests[0]["power"]["action"].getStr == verb
    let refused = jumpctl(["poweroff"], @[step(err("E_SHUTDOWN", "already shutting down"))], mode = "system")
    check refused.stdout == ""
    check refused.code == 1

  test "users list":
    let r = jumpctl(["users", "list"], @[step(ok(%*{"users": [
      {"uid": 1000, "user": "alice", "sessions": 2, "state": "running", "linger": true},
      {"uid": 1001, "user": "bob", "sessions": 0, "state": "stopping", "linger": false}]}))],
      mode = "system")
    check r.stdout == "1000 alice 2 running linger\n1001 bob 0 stopping -\n"
    check r.requests[0]["users"]["action"].getStr == "list"

  test "users linger is local and atomic":
    # Root cannot linger, so a root test run uses another account.
    let me = if getuid() == 0: "nobody" else: $getpwuid(getuid()).pwName
    check local(["users", "linger", "list"], mode = "system").stdout == ""
    var r = local(["users", "linger", "enable", me], mode = "system")
    check r.code == 0
    check r.stdout == "jumpctl: enabled linger for " & me & "\n"
    check fileExists(fixture / "etc/users/linger" / me)
    check local(["users", "linger", "list"], mode = "system").stdout == me & "\n"
    r = local(["users", "linger", "disable", me], mode = "system")
    check r.stdout == "jumpctl: disabled linger for " & me & "\n"
    check not fileExists(fixture / "etc/users/linger" / me)
    r = local(["users", "linger", "enable", "no-such-user-jumpctl"], mode = "system")
    check r.code == 1
    check r.stderr.startsWith("jumpctl: E_NOT_FOUND: ")
    r = local(["users", "linger", "enable", "root"], mode = "system")
    check r.code == 2

  test "env list, set, unset, and import":
    var r = jumpctl(["env", "list"], @[step(ok(%*{"vars": {"WAYLAND_DISPLAY": "wayland-0", "DISPLAY": ":0"}}))])
    check r.stdout == "DISPLAY=:0\nWAYLAND_DISPLAY=wayland-0\n"
    r = jumpctl(["env", "set", "DISPLAY=:1", "EMPTY="], @[step(ok())])
    check r.requests[0]["env"] == %*{"action": "set", "vars": {"DISPLAY": ":1", "EMPTY": ""}}
    check r.stdout == "jumpctl: set DISPLAY\njumpctl: set EMPTY\n"
    r = jumpctl(["env", "unset", "DISPLAY"], @[step(ok())])
    check r.requests[0]["env"] == %*{"action": "unset", "vars": {"DISPLAY": ""}}
    check r.stdout == "jumpctl: unset DISPLAY\n"
    r = jumpctl(["env", "import", "DISPLAY", "MISSING_VAR"], @[step(ok())],
      env = [("DISPLAY", ":7")])
    check r.requests[0]["env"] == %*{"action": "set", "vars": {"DISPLAY": ":7"}}
    check r.stdout == "jumpctl: imported DISPLAY\n"
    check r.stderr == "jumpctl: warning: MISSING_VAR is not set; skipped\n"
    for args in [@["env", "set", "HOME=/x"], @["env", "unset", "JUMPSTART_MODE"],
                 @["env", "set", "lower=1"], @["env", "set", "NOVALUE"], @["env", "import", "USER"]]:
      let bad = local(args)
      check bad.code == 2

suite "cores (§21.10 - §21.15)":
  test "cores list is local, in listing order, and skips invalid extensions":
    resetFixture()
    var r = local(["cores", "list"], mode = "system")
    check r.code == 0
    check r.stdout == "serviceHandler\ndelegator\ndemo\n"
    check r.stderr == ""
    r = local(["cores", "list", "--enabled"], mode = "system")
    check r.stdout == "serviceHandler\n"
    r = local(["cores", "list"], mode = "user")
    check r.stdout == "serviceHandler\ndelegator\ndemo\n"

  test "cores list --loaded uses the socket and keeps listing order":
    let r = jumpctl(["cores", "list", "--loaded"], @[step(ok(%*{"cores": [
      {"name": "serviceHandler", "state": "loaded"}, {"name": "demo", "state": "failed",
       "error": {"code": "E_INIT", "message": "init failed"}},
      {"name": "zeta", "state": "degraded", "stale": true}]}))])
    check r.stdout == "serviceHandler\nzeta\n"
    check r.requests[0]["core"] == %*{"action": "status"}

  test "cores status prints state, staleness, failures, and E_STATE first":
    var r = jumpctl(["cores", "status"], @[step(ok(%*{
      "state_error": {"code": "E_STATE", "message": "enabled directory is empty"},
      "cores": [{"name": "serviceHandler", "state": "loaded", "stale": false},
                {"name": "systemd", "state": "loaded", "stale": true},
                {"name": "openrc", "state": "failed", "error": {"code": "E_INIT", "message": "init\nfailed"}},
                {"name": "dinit", "state": "unloaded"}]}))])
    check r.stdout == "E_STATE: enabled directory is empty\nserviceHandler loaded\nsystemd loaded stale\n" &
      "openrc failed E_INIT: init failed\ndinit unloaded\n"
    r = jumpctl(["cores", "status", "systemd"], @[step(ok(%*{"cores": [{"name": "systemd", "state": "loading"}]}))])
    check r.requests[0]["core"] == %*{"action": "status", "name": "systemd"}
    check r.stdout == "systemd loading\n"

  test "live core commands":
    for (verb, text) in [("load", "jumpctl: loaded core demo\n"), ("unload", "jumpctl: unloaded core demo\n"),
                         ("reload", "jumpctl: reloaded core demo\n")]:
      let r = jumpctl(["cores", verb, "demo"], @[step(ok(%*{"changed": true}))])
      check r.stdout == text
      check r.requests[0]["core"]["action"].getStr == verb
    let r = jumpctl(["cores", "unload", "demo", "--stop-units"], @[step(err("E_BUSY", "active units"))])
    check r.requests[0]["core"] == %*{"action": "unload", "name": "demo", "stop_units": true}
    check r.stderr == "jumpctl: demo: E_BUSY: active units\n"
    check r.code == 1

  test "cores enable and disable without --now are local":
    resetFixture()
    var r = local(["cores", "enable", "demo"], mode = "system")
    check r.code == 0
    check r.stdout == "jumpctl: enabled core demo\n"
    check fileExists(enabledDir("system") / "demo")
    check fileExists(enabledDir("system") / "serviceHandler")
    r = local(["cores", "enable", "demo"], mode = "system")
    check r.code == 0
    r = local(["cores", "disable", "demo"], mode = "system")
    check r.stdout == "jumpctl: disabled core demo\n"
    check not fileExists(enabledDir("system") / "demo")
    r = local(["cores", "disable", "serviceHandler"], mode = "system")
    check r.code == 1
    check r.stderr.startsWith("jumpctl: serviceHandler: E_STATE: ")
    r = local(["cores", "enable", "nope"], mode = "system")
    check r.stderr == "jumpctl: nope: E_NOT_FOUND: core not found: nope\n"
    r = local(["cores", "enable", "broken"], mode = "system")
    check r.stderr.startsWith("jumpctl: broken: E_MANIFEST: ")
    r = local(["cores", "enable", "delegator"], mode = "system")
    check r.stderr.startsWith("jumpctl: delegator: E_DELEGATION: ")
    for bad in ["9bad", "jumpstart", "a/b"]:
      r = local(["cores", "enable", bad, "--now"], mode = "system")
      check r.code == 1
      check r.stderr.startsWith("jumpctl: " & bad & ": E_NAME: ")

  test "enable --now and disable --now persist only after the live change":
    resetFixture()
    var r = jumpctl(["cores", "enable", "demo", "--now"], @[step(err("E_INIT", "init failed", "demo"))],
      mode = "system")
    check r.code == 1
    check r.stderr == "jumpctl: demo: E_INIT: init failed\n"
    check not fileExists(enabledDir("system") / "demo")
    r = jumpctl(["cores", "enable", "demo", "--now"], @[step(ok(%*{"changed": true}))], mode = "system")
    check r.code == 0
    check r.requests[0]["core"] == %*{"action": "load", "name": "demo"}
    check r.stdout == "jumpctl: enabled core demo\n"
    check fileExists(enabledDir("system") / "demo")
    r = jumpctl(["cores", "disable", "demo", "--now", "--stop-units"],
      @[step(err("E_BUSY", "active units"))], mode = "system")
    check r.code == 1
    check fileExists(enabledDir("system") / "demo")
    r = jumpctl(["cores", "disable", "demo", "--now", "--stop-units"], @[step(ok())], mode = "system")
    check r.requests[0]["core"] == %*{"action": "unload", "name": "demo", "stop_units": true}
    check r.stdout == "jumpctl: disabled core demo\n"
    check not fileExists(enabledDir("system") / "demo")

  test "predictable persistent failures fail before the live step (§21.14)":
    resetFixture()
    # E_DELEGATION: delegator needs demo, which is not enabled.
    var r = jumpctl(["cores", "enable", "delegator", "--now"], @[], mode = "system")
    check r.code == 1
    check r.requests.len == 0
    check r.stdout == ""
    check r.stderr == "jumpctl: delegator: E_DELEGATION: delegation target demo is not enabled\n"
    # E_STATE: disabling the only enabled core would empty the set.
    r = jumpctl(["cores", "disable", "serviceHandler", "--now"], @[], mode = "system")
    check r.code == 1
    check r.requests.len == 0
    check r.stderr == "jumpctl: serviceHandler: E_STATE: cannot disable the last enabled core\n"
    # An undiscovered core.
    r = jumpctl(["cores", "enable", "nope", "--now"], @[], mode = "system")
    check r.code == 1
    check r.requests.len == 0
    check "E_NOT_FOUND" in r.stderr
    # Nothing was written by any of the dry runs.
    check not dirExists(enabledDir("system"))

  test "a failed persistent write after a live change reports the mismatch":
    resetFixture()
    # The write cannot be predicted to fail: the lock is a symlink (O_NOFOLLOW).
    createDir(fixture / "etc/cores")
    createSymlink(fixture / "etc/elsewhere", fixture / "etc/cores/.lock")
    tidy(fixture)
    var r = jumpctl(["cores", "enable", "demo", "--now"], @[step(ok())], mode = "system")
    check r.code == 1
    check r.requests.len == 1
    check r.stdout == ""
    check r.stderr.startsWith("jumpctl: demo: E_IO: live and persistent states now differ: core " &
      "demo was loaded, but enabling it persistently failed: ")

  test "cores show prints the manifest and the resolved table":
    resetFixture()
    var r = local(["cores", "show", "demo"], mode = "system")
    check r.code == 0
    check r.stdout.startsWith("name: demo\ncore_version: 0.1.0\nversion: 255\njumpstart: >=1.0.0, <3.0.0\n" &
      "modes: system user\naccount: root\nenabled: no\nsubsystems: core\noperations:\n  core.verify")
    check "bin/adapter" in r.stdout
    r = local(["cores", "show", "demo", "--resolved"], mode = "user")
    check "(default)" in r.stdout
    check "user: " & $getpwuid(getuid()).pwName in r.stdout
    r = local(["cores", "show", "serviceHandler"], mode = "system")
    check r.stdout.startsWith("name: serviceHandler\n")
    check "enabled: yes\n" in r.stdout
    check "service.start" in r.stdout
    r = local(["cores", "show", "nope"])
    check r.code == 1

  test "cores check reports errors and warnings":
    resetFixture()
    var r = local(["cores", "check"], mode = "system")
    check r.code == 1
    check "jumpctl: broken: E_MANIFEST: " in r.stderr
    check "jumpctl: demo: warning: " in r.stderr
    check "function 'unused' is never referenced" in r.stderr
    r = local(["cores", "check", "demo"], mode = "system")
    check r.code == 0
    check r.stderr.startsWith("jumpctl: demo: warning: ")
    r = local(["cores", "check", "nope"], mode = "system")
    check r.code == 1
    check r.stderr == "jumpctl: nope: E_NOT_FOUND: core not found: nope\n"

  test "cores check rejects exec expressions reachable from a handler (§16.4)":
    resetFixture()
    let shelly = DemoManifest.replace("name: \"demo\"", "name: \"shelly\"").replace(
      "    backend: \"exec\"\n    options:\n      executable: \"bin/adapter\"\n      mode: \"oneshot\"\n      sandbox: true\n",
      "    backend: \"custom\"\n    functions:\n      - handler: \"verify\"\n    options:\n      sandbox: true\n").replace(
      "func unused {\n  print \"never called\"\n}\n",
      "func verify {\n  local x = \"${exec(\\\"id\\\")}\"\n  respond installed \"true\"\n}\n")
    writePrivate(fixture / "lib/cores/shelly/init.kg", shelly)
    tidy(fixture)
    var r = local(["cores", "check", "shelly"], mode = "system")
    check r.code == 1
    check "jumpctl: shelly: E_MANIFEST: " in r.stderr
    check "reach an exec" in r.stderr

  test "cores run executes a core operation without the daemon":
    resetFixture()
    # core.verify is read-only, so it always runs sandboxed (§13.1); hosts
    # without the sandbox (macOS, unprivileged containers) fail closed.
    let runMode = if getuid() == 0: "system" else: "user"
    for core in ["demo", "delegator"]:
      let r = local(["cores", "run", core, "core.verify"], mode = runMode)
      if r.code == 0:
        check r.stdout == "installed: true\nversion: 255\n"
      else:
        check r.code == 1
        check r.stdout == ""
        check r.stderr.startsWith("jumpctl: demo: E_SANDBOX: ")
    var r: Run
    r = local(["cores", "run", "serviceHandler", "core.verify"], mode = "user")
    check r.code == 3
    r = local(["cores", "run", "demo", "core.verify", "extra=1"], mode = "user")
    check r.code == 2
    r = local(["cores", "run", "demo", "core.bogus"], mode = "user")
    check r.code == 3
    # Non-core operations are no longer rejected as usage errors (§21.15):
    # `demo` simply does not claim `unit`.
    r = local(["cores", "run", "demo", "unit.list"], mode = "user")
    check r.code == 3
    check r.stderr == "jumpctl: demo: E_UNSUPPORTED: operation is not supported: unit.list\n"

# ---------------------------------------------------------------------------
# `cores run` of any operation (§21.15)

const
  PersistentOps = ["unit.list", "unit.resolve", "service.status", "log.read", "log.follow"]
  OneshotOps = ["service.start", "service.enable", "service.restart", "service.reload"]

const PersistentAdapter = r"""#!/bin/sh
# A persistent exec adapter (§17.6) that answers a few registry operations.
read -r hello <&3
printf '%s\n' '{"type":"hello","protocol":"jumpstart-core/1","role":"adapter","operations":[@OPS@]}' >&4
field() { printf '%s' "$request" | sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p"; }
while read -r request <&3; do
  id=$(field id); op=$(field op); unit=$(field unit)
  case $op in
    unit.list)
      printf '{"type":"event","id":"%s","event":"item","field":"units","data":{"name":"alpha","subsystem":"service","enablement":"enabled"}}\n' "$id" >&4
      printf '{"type":"event","id":"%s","event":"item","field":"units","data":{"name":"beta","subsystem":"service","enablement":"static"}}\n' "$id" >&4
      printf '{"type":"response","id":"%s","status":"ok","result":{"units":[{"name":"gamma","subsystem":"service","enablement":"masked"}]}}\n' "$id" >&4 ;;
    unit.resolve)
      printf '{"type":"response","id":"%s","status":"ok","result":{"owned":true,"name":"resolved","subsystem":"service"}}\n' "$id" >&4 ;;
    service.status)
      case $unit in
        bad) printf '{"type":"response","id":"%s","status":"error","error":{"code":"E_NOT_FOUND","message":"no such unit: bad"}}\n' "$id" >&4 ;;
        invalid) printf '{"type":"response","id":"%s","status":"ok","result":{"state":"bogus","detail":"","enablement":"enabled"}}\n' "$id" >&4 ;;
        *) printf '{"type":"response","id":"%s","status":"ok","result":{"state":"active","detail":"unit=<%s>","enablement":"enabled","main_pid":42,"pids":[42,43]}}\n' "$id" "$unit" >&4 ;;
      esac ;;
    log.read)
      printf '{"type":"response","id":"%s","status":"ok","result":{"entries":[{"time":"2026-10-17T10:00:00Z","level":"info","unit":"%s","message":"hello"},{"time":"2026-10-17T10:00:01Z","level":"warn","unit":"%s","message":"again"}]}}\n' "$id" "$unit" "$unit" >&4 ;;
    log.follow)
      printf '{"type":"event","id":"%s","event":"entry","data":{"time":"2026-10-17T10:00:00Z","level":"info","unit":"%s","message":"first"}}\n' "$id" "$unit" >&4
      printf '{"type":"event","id":"%s","event":"entry","data":{"time":"2026-10-17T10:00:01Z","level":"debug","unit":"%s","message":"second"}}\n' "$id" "$unit" >&4
      : > "@MARKERS@/follow"
      while read -r line <&3; do
        case $line in
          *'"type":"cancel"'*)
            printf '{"type":"response","id":"%s","status":"error","error":{"code":"E_CANCELLED","message":"cancelled"}}\n' "$id" >&4
            break ;;
        esac
      done ;;
  esac
done
"""

const OneshotAdapter = r"""#!/bin/sh
# A oneshot exec adapter (§17.6) for mutating operations. It reports the
# request variables of §16.2 on standard output.
read -r hello <&3
printf '%s\n' '{"type":"hello","protocol":"jumpstart-core/1","role":"adapter","operations":[@OPS@]}' >&4
read -r request <&3
id=$(printf '%s' "$request" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
echo "op=$JUMPSTART_OP unit=$JUMPSTART_UNIT core=$JUMPSTART_CORE_NAME mode=$JUMPSTART_MODE arg_now=$JUMPSTART_ARG_NOW arg_target=$JUMPSTART_ARG_TARGET request=${JUMPSTART_REQUEST_ID:+set}"
case $JUMPSTART_OP in
  service.restart|service.reload)
    : > "@MARKERS@/$JUMPSTART_OP"
    exec sleep 1000 ;;
  service.enable)
    printf '{"type":"response","id":"%s","status":"ok","result":{}}\n' "$id" >&4 ;;
  *)
    printf '{"type":"response","id":"%s","status":"ok","result":{"state":"active"}}\n' "$id" >&4 ;;
esac
"""

proc quoted(names: openArray[string]): string =
  for i, name in names:
    if i > 0: result.add ","
    result.add "\"" & name & "\""

proc execEntry(op, exe, mode, timeout: string; extra = ""): string =
  "  - name: \"" & op & "\"\n    backend: \"exec\"\n    options:\n      executable: \"bin/" &
    exe & "\"\n      mode: \"" & mode & "\"\n      timeout: \"" & timeout & "\"\n" & extra

proc customEntry(op, handler, timeout: string): string =
  "  - name: \"" & op & "\"\n    backend: \"custom\"\n    functions:\n      - handler: \"" &
    handler & "\"\n    options:\n      timeout: \"" & timeout & "\"\n"

proc delegateEntry(op, core: string; operation = ""): string =
  "  - name: \"" & op & "\"\n    backend: \"delegate\"\n    options:\n      core: \"" & core & "\"\n" &
    (if operation.len > 0: "      operation: \"" & operation & "\"\n" else: "")

proc coreManifest(name: string; subsystems: openArray[string];
                  entries: Table[string, string]; body = "init {\n  print \"init\"\n}\n"): string =
  ## Every verb of a claimed subsystem has an entry (§11.3); the others are
  ## `unsupported`.
  result = "manifest_version: 1\nname: \"" & name & "\"\ndescription: \"Run fixture\"\n" &
    "core_version: \"0.1.0\"\nversion: \"1\"\njumpstart: \">=1.0.0, <3.0.0\"\n" &
    "modes:\n  - \"system\"\n  - \"user\"\nsubsystems:\n"
  for sub in subsystems: result.add "  - \"" & sub & "\"\n"
  if "service" in subsystems: result.add "activation: \"per-unit\"\n"
  result.add "supported_ops:\n"
  for sub in subsystems:
    for spec in operationsForSubsystem(1, sub):
      result.add entries.getOrDefault(spec.name,
        "  - name: \"" & spec.name & "\"\n    backend: \"unsupported\"\n")
  result.add body

let runMode = if getuid() == 0: "system" else: "user"
let runRoot = if runMode == "system": fixture / "lib/cores" else: fixture / "home/cores"
let markers = fixture / "markers"

proc executable(path, content: string) =
  writePrivate(path, content)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead, fpGroupExec,
    fpOthersRead, fpOthersExec})

proc writeDebugCores() =
  ## `dbg`: every backend; `hops1..hops5`/`cyca`/`cycb`: delegation chains.
  var entries = initTable[string, string]()
  for op in PersistentOps:
    entries[op] = execEntry(op, "persist", "persistent", if op == "unit.resolve": "5s" else: "10s")
  entries["service.start"] = execEntry("service.start", "oneshot", "oneshot", "10s")
  entries["service.enable"] = execEntry("service.enable", "oneshot", "oneshot", "10s")
  entries["service.restart"] = execEntry("service.restart", "oneshot", "oneshot", "1s")
  entries["service.reload"] = execEntry("service.reload", "oneshot", "oneshot", "60s")
  entries["service.stop"] = customEntry("service.stop", "stopper", "10s")
  entries["service.kill"] = execEntry("service.kill", "slowpoke", "oneshot", "10s")
  # service.kill is routed to an executable that is never started: its
  # handshake would fail, which is exactly what the mismatch test uses.
  let handlers = """func stopper {
  print "custom stopper ran"
  respond state "inactive"
}
"""
  writePrivate(runRoot / "dbg/init.kg", coreManifest("dbg", ["core", "unit", "service", "log"], entries,
    "init {\n  print \"init\"\n}\n" & handlers))
  executable(runRoot / "dbg/bin/persist", PersistentAdapter.replace("@OPS@", quoted(PersistentOps)).replace("@MARKERS@", markers))
  executable(runRoot / "dbg/bin/oneshot", OneshotAdapter.replace("@OPS@", quoted(OneshotOps)).replace("@MARKERS@", markers))
  # `slowpoke` answers a wrong operation set (§17.2).
  executable(runRoot / "dbg/bin/slowpoke", OneshotAdapter.replace("@OPS@", "\"service.stop\"").replace("@MARKERS@", markers))
  # Chains of `unit.list` delegations.
  proc chain(name, target: string) =
    var e = initTable[string, string]()
    e["unit.list"] = delegateEntry("unit.list", target)
    writePrivate(runRoot / name / "init.kg", coreManifest(name, ["unit"], e))
  for i in 1 .. 4: chain("hops" & $i, "hops" & $(i + 1))
  chain("hops5", "dbg")
  chain("cyca", "cycb")
  chain("cycb", "cyca")
  # A delegation of a unit-addressed verb, and to a core that is not there.
  var d = initTable[string, string]()
  d["unit.list"] = delegateEntry("unit.list", "dbg")
  d["unit.resolve"] = delegateEntry("unit.resolve", "dbg")
  d["service.status"] = delegateEntry("service.status", "dbg")
  d["service.start"] = delegateEntry("service.start", "dbg")
  d["service.stop"] = delegateEntry("service.stop", "missing")
  writePrivate(runRoot / "deleg/init.kg", coreManifest("deleg", ["unit", "service"], d))
  tidy(fixture)

proc runCoreWith(args: seq[string]; interruptOn = ""): Run =
  local(@["cores", "run"] & args, mode = runMode,
    env = [("JUMPCTL_TEST_RUNNER", runner)], interruptOn = interruptOn)

proc runCore(args: varargs[string]): Run = runCoreWith(@args)

suite "cores run of any operation (§21.15)":
  resetFixture()
  createDir(markers)
  writeDebugCores()

  test "a persistent adapter answers a unit operation, with UNIT exactly as typed":
    let r = runCore("dbg", "service.status", "Getty@TTY1.Service")
    check r.code == 0
    check r.stdout == "state: active\ndetail: unit=<Getty@TTY1.Service>\nenablement: enabled\n" &
      "main_pid: 42\npids: 42, 43\n"
    check "warning" notin r.stderr
    # `unit.resolve` is not applied: the name reaches the adapter unchanged.
    check runCore("dbg", "unit.resolve", "x").code == 2
    check runCore("dbg", "unit.resolve", "name=x.service").stdout ==
      "owned: true\nname: resolved\nsubsystem: service\n"

  test "list items print as they arrive, without the CORE/ prefix":
    let r = runCore("dbg", "unit.list")
    check r.code == 0
    check r.stdout == "alpha service enabled\nbeta service static\ngamma service masked\n"
    check "warning" notin r.stderr

  test "log operations take an optional UNIT and print the log line format":
    var r = runCore("dbg", "log.read", "alpha")
    check r.code == 0
    check r.stdout == "2026-10-17T10:00:00Z info alpha hello\n2026-10-17T10:00:01Z warn alpha again\n"
    r = runCore("dbg", "log.read")
    check r.stdout == "2026-10-17T10:00:00Z info - hello\n2026-10-17T10:00:01Z warn - again\n"
    check "warning" notin r.stderr

  test "errors keep their code and an invalid result is E_PROTOCOL":
    var r = runCore("dbg", "service.status", "bad")
    check r.code == 1
    check r.stdout == ""
    check r.stderr == "jumpctl: dbg: E_NOT_FOUND: no such unit: bad\n"
    r = runCore("dbg", "service.status", "invalid")
    check r.code == 1
    check r.stderr.startsWith("jumpctl: dbg: E_PROTOCOL: ")
    check r.stdout == ""

  test "a oneshot adapter gets the request environment; mutating operations warn":
    var r = runCore("dbg", "service.start", "my.service")
    check r.code == 0
    check r.stdout == "state: active\n"
    check "jumpctl: warning: running service.start outside the daemon: no locking, " &
      "supervision or daemon state; for debugging only\n" in r.stderr
    check ("core:dbg: op=service.start unit=my.service core=dbg mode=" & runMode &
      " arg_now= arg_target= request=set\n") in r.stderr
    r = runCore("dbg", "service.enable", "my.service", "now=true", "target=boot.target")
    check r.code == 0
    check r.stdout == ""
    check "arg_now=true arg_target=boot.target" in r.stderr
    check r.stderr.count("warning") == 1

  test "a custom backend runs in the Kongue runner":
    let r = runCore("dbg", "service.stop", "my.service")
    check r.code == 0
    check r.stdout == "state: inactive\n"
    check "core:dbg: " in r.stderr and "custom stopper ran" in r.stderr
    check "warning: running service.stop outside the daemon" in r.stderr

  test "delegation runs the target core's backend locally":
    var r = runCore("deleg", "service.status", "t.service")
    check r.code == 0
    check r.stdout.startsWith("state: active\ndetail: unit=<t.service>\n")
    r = runCore("deleg", "unit.list")
    check r.stdout == "alpha service enabled\nbeta service static\ngamma service masked\n"
    r = runCore("deleg", "service.start", "t.service")
    check r.code == 0
    check "warning: running service.start" in r.stderr
    check "core:dbg: op=service.start unit=t.service core=dbg" in r.stderr
    # §13.4: a missing target is E_DELEGATION, never a fallback.
    r = runCore("deleg", "service.stop", "t.service")
    check r.code == 1
    check "E_DELEGATION" in r.stderr
    # Chains: four delegations run, five are rejected, cycles are rejected.
    check runCore("hops2", "unit.list").code == 0
    r = runCore("hops1", "unit.list")
    check r.code == 1
    check r.stderr == "jumpctl: hops5: E_DELEGATION: delegation chain exceeds four hops\n"
    r = runCore("cyca", "unit.list")
    check r.code == 1
    check "E_DELEGATION: delegation cycle" in r.stderr

  test "unsupported, undeclared and native operations are E_UNSUPPORTED":
    var r = runCore("dbg", "service.disable", "x")
    check r.code == 3
    check r.stderr == "jumpctl: dbg: E_UNSUPPORTED: operation is not supported: service.disable\n"
    check r.stdout == ""
    check runCore("dbg", "mount.status", "x").code == 3
    check runCore("dbg", "target.get-default").code == 3
    check runCore("dbg", "core.bogus").code == 3
    r = runCore("serviceHandler", "service.start", "x")
    check r.code == 3
    check r.stderr == "jumpctl: serviceHandler: E_UNSUPPORTED: native operations need the " &
      "daemon: use the normal jumpctl commands\n"
    check "warning" notin r.stderr
    check runCore("serviceHandler", "unit.list").code == 3
    check runCore("serviceHandler", "core.verify").code == 3
    check runCore("nosuchcore", "unit.list").code == 1

  test "wrong UNIT usage is E_USAGE (exit 2) and starts nothing":
    for args in [@["dbg", "service.status"], @["dbg", "service.start", "now=true"],
                 @["dbg", "unit.list", "x"], @["dbg", "core.verify", "x"],
                 @["dbg", "service.status", "dbg/x"], @["dbg", "service.status", "a", "b"],
                 @["dbg", "service.status", "a", "bogus=1"], @["dbg", "log.read", "a", "lines=x"],
                 @["dbg", "verify"], @["dbg"]]:
      let r = runCoreWith(args)
      check r.code == 2
      check r.stdout == ""
      check r.stderr.startsWith("jumpctl: E_USAGE: ")
      check "warning" notin r.stderr
    check "not CORE/UNIT" in runCore("dbg", "service.status", "dbg/x").stderr

  test "an adapter whose hello disagrees with the routed set is E_PROTOCOL (§17.2)":
    let r = runCore("dbg", "service.kill", "x", "signal=TERM")
    check r.code == 1
    check "E_PROTOCOL" in r.stderr

  test "the operation's own timeout bounds the run (§11.6)":
    removeFile(markers / "service.restart")
    let started = epochTime()
    let r = runCore("dbg", "service.restart", "slow.service")
    check r.code == 4
    check r.stderr.endsWith("jumpctl: dbg: E_TIMEOUT: operation timed out\n")
    check epochTime() - started < 20

  test "Ctrl-C cancels the request with E_CANCELLED (exit 4)":
    removeFile(markers / "service.reload")
    let r = runCoreWith(@["dbg", "service.reload", "slow.service"], interruptOn = markers / "service.reload")
    check r.code == 4
    check "E_CANCELLED" in r.stderr
    check "warning: running service.reload" in r.stderr

  test "Ctrl-C ends a streaming operation after its entries, normally":
    removeFile(markers / "follow")
    let r = runCoreWith(@["dbg", "log.follow", "alpha"], interruptOn = markers / "follow")
    check r.code == 0
    check r.stdout == "2026-10-17T10:00:00Z info alpha first\n2026-10-17T10:00:01Z debug alpha second\n"
    check "warning" notin r.stderr

  test "the core need not be enabled or loaded, and no daemon is contacted":
    let r = local(["cores", "show", "dbg"], mode = runMode)
    check "enabled: no\n" in r.stdout
    check not dirExists(enabledDir(runMode))
    check runCore("dbg", "unit.list").code == 0

when not defined(keepFixture): removeDir(fixture)
