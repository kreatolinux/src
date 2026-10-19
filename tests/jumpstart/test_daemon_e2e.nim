## End-to-end tests of the running daemon (jumpstart-cores §27.6-§27.8).
##
## The real `jumpstart` binary is built with -d:jumpstartTestHooks, which
## roots every path in a fixture directory (the layout of jumpctl's
## -d:jumpctlTestHooks) and skips the PID 1 duties. Requests go through the
## real control socket, either from the real `jumpctl` (built with its test
## hooks) or as raw §14.5 lines. Extension cores need cgroup v2: those tests
## run only as root on Linux with a writable /sys/fs/cgroup (a privileged
## container) and are skipped elsewhere.
import std/[json, os, osproc, posix, streams, strtabs, strutils, times, unittest]
import std/net
import jumpstartcore/registry

const RepoRoot = currentSourcePath().parentDir.parentDir.parentDir

let binDir = getAppDir()
let fixture = binDir / "jsd-e2e"
let daemonBin = binDir / "jumpstart-e2e"
let jumpctlBin = binDir / "jumpctl-e2e"
let runnerBin = binDir / "kongue-runner-e2e"

proc build(source, output, flags: string) =
  let cmd = quoteShell(getCurrentCompilerExe()) & " c --hints:off " & flags &
    " -o:" & quoteShell(output) & " " & quoteShell(RepoRoot / source)
  let (text, code) = execCmdEx(cmd)
  if code != 0:
    echo text
    quit "cannot build " & source

build("jumpstart/jumpstart.nim", daemonBin,
  "--threads:on --mm:refc -d:jumpstartTestHooks")
build("jumpstart/jumpctl.nim", jumpctlBin, "--threads:off -d:jumpctlTestHooks")
build("jumpstart/kongue_runner.nim", runnerBin, "--threads:off")

let isRoot = getuid() == 0
let cgroupBase = "/sys/fs/cgroup"
let extensionCapable = defined(linux) and isRoot and
  fileExists(cgroupBase / "cgroup.controllers") and
  (block:
    # cgroup directories are removed with rmdir(2), never recursively.
    let probe = cgroupBase / "jsd-probe"
    let made = posix.mkdir(probe.cstring, Mode(0o755)) == 0
    if made: discard posix.rmdir(probe.cstring)
    made)

# ---------------------------------------------------------------------------
# Fixture

proc private(path: string) =
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})

proc publicDir(path: string) =
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead,
    fpGroupExec, fpOthersRead, fpOthersExec})

proc tidy(path: string) =
  ## Directories 0755, files not writable by others (§8.3).
  publicDir(path)
  for kind, entry in walkDir(path):
    if kind == pcDir: tidy(entry)

proc writeText(path, content: string; executable = false) =
  createDir(parentDir(path))
  writeFile(path, content)
  var perms = {fpUserRead, fpUserWrite, fpGroupRead, fpOthersRead}
  if executable: perms = perms + {fpUserExec, fpGroupExec, fpOthersExec}
  setFilePermissions(path, perms)

var testCgroup = ""
var daemons: seq[Process]   # killed before the next test if a check aborted one

proc resetFixture() =
  for p in daemons:
    if p.running:
      discard posix.kill(Pid(p.processID), SIGKILL)
      discard p.waitForExit()
  daemons.setLen(0)
  if dirExists(fixture): removeDir(fixture)
  createDir(fixture)
  publicDir(fixture)
  for dir in ["lib/cores", "etc", "var", "run", "home"]:
    createDir(fixture / dir)
  tidy(fixture)
  if extensionCapable:
    testCgroup = cgroupBase / ("jsd-" & $getpid())
    if dirExists(testCgroup):
      discard execCmdEx("find " & quoteShell(testCgroup) & " -depth -type d -exec rmdir {} +")
    createDir(testCgroup)

proc enable(names: openArray[string]; mode = "system") =
  let dir = if mode == "system": fixture / "etc/cores/enabled"
            else: fixture / "home/config/cores/enabled"
  createDir(dir)
  private(parentDir(dir))
  private(dir)
  for name in names: writeFile(dir / name, "")

const AdapterOps = ["unit.list", "unit.resolve", "unit.activate",
  "unit.deactivate", "unit.validate", "unit.load", "service.start",
  "service.stop", "service.restart", "service.kill", "service.enable",
  "service.disable", "log.follow"]

proc adapterScript(): string =
  var ops: seq[string]
  for op in AdapterOps: ops.add "\"" & op & "\""
  result = """#!/bin/sh
# A oneshot exec adapter (§17) for the e2e demo core. Unit state lives in
# files below the core's state directory.
read -r hello <&3
printf '%s\n' '{"type":"hello","protocol":"jumpstart-core/1","role":"adapter","operations":[""" &
    ops.join(",") & """]}' >&4
read -r request <&3
id=$(printf '%s' "$request" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
st="$JUMPSTART_CORE_STATE_DIR"
u="$JUMPSTART_UNIT"
reply() { printf '{"type":"response","id":"%s","status":"ok","result":%s}\n' "$id" "$1" >&4; }
fail() { printf '{"type":"response","id":"%s","status":"error","error":{"code":"%s","message":"%s"}}\n' "$id" "$1" "$2" >&4; }
case "$JUMPSTART_OP" in
  unit.list)
    reply '{"units":[{"name":"alpha.service","subsystem":"service","enablement":"enabled"},{"name":"beta.service","subsystem":"service","enablement":"disabled"}]}' ;;
  unit.resolve)
    n="$JUMPSTART_ARG_NAME"
    case "$n" in
      missing*) reply '{"owned":false,"name":"","subsystem":""}' ;;
      *.service) reply "{\"owned\":true,\"name\":\"$n\",\"subsystem\":\"service\"}" ;;
      *) reply "{\"owned\":true,\"name\":\"$n.service\",\"subsystem\":\"service\"}" ;;
    esac ;;
  unit.activate)
    # The `gate` core's activation waits for the test (§20.2 step 1, filesystems ready).
    if [ "$JUMPSTART_CORE_NAME" = gate ]; then
      while [ ! -e "$JUMPSTART_CORE_ROOT/../../../activate-flag" ]; do sleep 0.2; done
    fi
    touch "$st/activated"; reply '{"started":1,"failed":[]}' ;;
  unit.deactivate)
    # A core that never finishes stopping its units (§20.9 limits).
    if [ -e "$JUMPSTART_CORE_ROOT/bin/hang-deactivate" ]; then sleep 100; fi
    touch "$st/deactivated"; reply '{"stopped":0,"failed":[]}' ;;
  unit.load) reply '{"loaded":2,"errors":[]}' ;;
  unit.validate) sleep 3; reply '{"valid":true,"diagnostics":[]}' ;;
  service.start)
    touch "$st/$u.active"
    case "$u" in
      orphan.service)   # a daemon that outlives its starter: Jumpstart inherits it (§15.3)
        ( sleep 1 3<&- 4<&- </dev/null >/dev/null 2>&1 & ) ;;
      leak.service)     # a process left in the control cgroup
        sleep 300 3<&- 4<&- </dev/null >/dev/null 2>&1 &
        echo $! > "$st/leak.pid" ;;
      held.service)     # a unit process in the core's units/ cgroup
        cg=$(sed -n 's/^0:://p' /proc/self/cgroup)
        sleep 300 3<&- 4<&- </dev/null >/dev/null 2>&1 &
                echo $! > "/sys/fs/cgroup${cg%/control}/units/cgroup.procs"
        echo $! > "$st/held.pid" ;;
    esac
    reply '{"state":"active"}' ;;
  service.stop) rm -f "$st/$u.active"; reply '{"state":"inactive"}' ;;
  service.restart) sleep "${JUMPSTART_ARG_DELAY:-3}"; touch "$st/$u.restarted"; reply '{"state":"active"}' ;;
  service.kill) printf '%s' "$JUMPSTART_ARG_SIGNAL" > "$st/$u.killed"; reply '{}' ;;
  service.enable) printf '%s' "$JUMPSTART_ARG_NOW" > "$st/$u.enabled"; reply '{}' ;;
  service.disable) printf '%s' "$JUMPSTART_ARG_NOW" > "$st/$u.disabled"; reply '{}' ;;
  log.follow)
    while :; do
      printf '{"type":"event","id":"%s","event":"entry","data":{"time":"2026-01-01T00:00:00Z","level":"info","unit":"%s","message":"tick"}}\n' "$id" "$u" >&4
      sleep 0.2
    done ;;
  *) fail E_UNSUPPORTED "unexpected $JUMPSTART_OP" ;;
esac
"""

const VerifyScript = """#!/bin/sh
read -r hello <&3
printf '%s\n' '{"type":"hello","protocol":"jumpstart-core/1","role":"adapter","operations":["core.verify"]}' >&4
read -r request <&3
id=$(printf '%s' "$request" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
printf '{"type":"response","id":"%s","status":"ok","result":{"installed":true,"version":"1"}}\n' "$id" >&4
"""

proc header(name: string; subsystems: openArray[string]; activation = "";
            supervisor = false): string =
  result = "manifest_version: 1\nname: \"" & name & "\"\ndescription: \"" & name &
    " core\"\ncore_version: \"0.1.0\"\nversion: \"1\"\njumpstart: \">=2.0.0, <3.0.0\"\n" &
    "modes:\n  - \"system\"\n  - \"user\"\nsubsystems:\n"
  for s in subsystems: result.add "  - \"" & s & "\"\n"
  if activation.len > 0: result.add "activation: \"" & activation & "\"\n"
  if supervisor:
    result.add "supervisor:\n  executable: \"bin/supervisor\"\n  ready_timeout: \"10s\"\n"
  result.add "supported_ops:\n"

proc verifyOp(sandbox: bool): string =
  "  - name: \"core.verify\"\n    backend: \"exec\"\n    options:\n" &
    "      executable: \"bin/verify\"\n      mode: \"oneshot\"\n" &
    (if sandbox: "      sandbox: true\n      working_directory: \"/tmp\"\n" else: "") &
    "      timeout: \"10s\"\n"

proc persistentAdapterScript(ops: openArray[string]): string =
  ## A persistent exec adapter (§17.6): one long-lived process, requests
  ## served one after another. Its pid is appended to adapter.pids.
  var quoted: seq[string]
  for op in ops: quoted.add "\"" & op & "\""
  result = """#!/bin/sh
read -r hello <&3
printf '%s\n' '{"type":"hello","protocol":"jumpstart-core/1","role":"adapter","operations":[""" &
    quoted.join(",") & """]}' >&4
st="$JUMPSTART_CORE_STATE_DIR"
echo $$ >> "$st/adapter.pids"
while read -r request <&3; do
  kind=$(printf '%s' "$request" | sed -n 's/.*"type":"\([^"]*\)".*/\1/p')
  [ "$kind" = request ] || continue
  id=$(printf '%s' "$request" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
  op=$(printf '%s' "$request" | sed -n 's/.*"op":"\([^"]*\)".*/\1/p')
  u=$(printf '%s' "$request" | sed -n 's/.*"unit":"\([^"]*\)".*/\1/p')
  reply() { printf '{"type":"response","id":"%s","status":"ok","result":%s}\n' "$id" "$1" >&4; }
  case "$op" in
    unit.list)
      reply '{"units":[{"name":"alpha.service","subsystem":"service","enablement":"enabled"}]}' ;;
    unit.resolve)
      n=$(printf '%s' "$request" | sed -n 's/.*"args":{[^}]*"name":"\([^"]*\)".*/\1/p')
      case "$n" in
        *.service) reply "{\"owned\":true,\"name\":\"$n\",\"subsystem\":\"service\"}" ;;
        *) reply "{\"owned\":true,\"name\":\"$n.service\",\"subsystem\":\"service\"}" ;;
      esac ;;
    service.start)
      # The service is a process in the core's units/ cgroup, not a child that
      # the adapter's death would take with it.
      cg=$(sed -n 's/^0:://p' /proc/self/cgroup)
      sleep 300 3<&- 4<&- </dev/null >/dev/null 2>&1 &
      echo $! > "/sys/fs/cgroup${cg%/control}/units/cgroup.procs"
      echo $! > "$st/$u.pid"
      reply '{"state":"active"}' ;;
    unit.activate) reply '{"started":0,"failed":[]}' ;;
    unit.deactivate) reply '{"stopped":0,"failed":[]}' ;;
    unit.load) reply '{"loaded":0,"errors":[]}' ;;
    unit.validate) reply '{"valid":true,"diagnostics":[]}' ;;
    service.stop) reply '{"state":"inactive"}' ;;
    service.restart) reply '{"state":"active"}' ;;
    *) reply '{}' ;;
  esac
done
"""

proc demoCore(name = "demo"; initBody = "  print \"init\"\n"; extraFuncs = "";
              supervisorScript = ""; persistent = false) =
  ## `persistent`: the adapter runs as one long-lived process (log.follow, a
  ## streaming operation, stays unsupported). `supervisorScript`: the core
  ## declares a supervisor that runs it.
  let routed = block:
    var ops: seq[string]
    for op in AdapterOps:
      if not (persistent and op == "log.follow"): ops.add op
    ops
  var text = header(name, ["core", "unit", "service", "log"], "core",
    supervisor = supervisorScript.len > 0) & verifyOp(true)
  for op in routed:
    # §13.1: read-only and streaming oneshot/custom backends are sandboxed;
    # persistent exec entries never are.
    let sandboxed = not persistent and
      op in ["unit.list", "unit.resolve", "unit.validate", "log.follow"]
    text.add "  - name: \"" & op & "\"\n    backend: \"exec\"\n    options:\n" &
      "      executable: \"" & (if persistent: "bin/padapter" else: "bin/adapter") & "\"\n" &
      "      mode: \"" & (if persistent: "persistent" else: "oneshot") & "\"\n" &
      "      timeout: \"30s\"\n" &
      (if sandboxed: "      sandbox: true\n      working_directory: \"/tmp\"\n" else: "")
  text.add "  - name: \"service.status\"\n    backend: \"custom\"\n    functions:\n" &
    "      - handler: \"status\"\n    options:\n      timeout: \"10s\"\n      sandbox: true\n" &
    "      working_directory: \"/tmp\"\n"
  # §11.3: every operation of a claimed subsystem is declared.
  for sub in ["core", "unit", "service", "log"]:
    for spec in operationsForSubsystem(CurrentManifestVersion, sub):
      if spec.name notin routed and spec.name notin ["core.verify", "service.status"]:
        text.add "  - name: \"" & spec.name & "\"\n    backend: \"unsupported\"\n"
  text.add "init {\n" & initBody & "}\n"
  text.add "func status {\n  respond state \"active\"\n" &
    "  respond detail \"${JUMPSTART_CORE_NAME}|${JUMPSTART_OP}|${JUMPSTART_UNIT}|${JUMPSTART_MODE}\"\n" &
    "  respond enablement \"enabled\"\n}\n"
  text.add extraFuncs
  let dir = fixture / "lib/cores" / name
  writeText(dir / "init.kg", text)
  writeText(dir / "bin/adapter", adapterScript(), executable = true)
  if persistent: writeText(dir / "bin/padapter", persistentAdapterScript(routed), executable = true)
  if supervisorScript.len > 0: writeText(dir / "bin/supervisor", supervisorScript, executable = true)
  writeText(dir / "bin/verify", VerifyScript, executable = true)
  tidy(dir)

const IdleSupervisor = """#!/bin/sh
read -r hello <&3
printf '%s\n' '{"type":"hello","protocol":"jumpstart-core/1","role":"supervisor"}' >&4
echo $$ > "$JUMPSTART_CORE_RUNTIME_DIR/supervisor.pid"
while read -r line <&3; do :; done
"""

const ReadySupervisor = """#!/bin/sh
# Reports filesystems-ready (§17.5) once the test creates ready-flag.
read -r hello <&3
printf '%s\n' '{"type":"hello","protocol":"jumpstart-core/1","role":"supervisor"}' >&4
parent=$$
( while kill -0 $parent 2>/dev/null; do
    if [ -e "$JUMPSTART_CORE_ROOT/../../../ready-flag" ]; then
      printf '%s\n' '{"type":"filesystems-ready"}' >&4
      exit 0
    fi
    sleep 0.1
  done ) &
while read -r line <&3; do :; done
"""

proc plainCore(name, initBody: string; delegateTo = "") =
  var text = header(name, ["core"])
  if delegateTo.len > 0:
    text.add "  - name: \"core.verify\"\n    backend: \"delegate\"\n    options:\n" &
      "      core: \"" & delegateTo & "\"\n"
  else:
    text.add verifyOp(true)
  for spec in operationsForSubsystem(CurrentManifestVersion, "core"):
    if spec.name != "core.verify":
      text.add "  - name: \"" & spec.name & "\"\n    backend: \"unsupported\"\n"
  text.add "init {\n" & initBody & "}\n"
  let dir = fixture / "lib/cores" / name
  writeText(dir / "init.kg", text)
  writeText(dir / "bin/verify", VerifyScript, executable = true)
  tidy(dir)

proc nativeService(name, exec: string; mode = "system") =
  let dir = if mode == "system": fixture / "etc" else: fixture / "home/config"
  createDir(dir)
  writeFile(dir / (name & ".kg"), "description: \"" & name & "\"\ntype: \"simple\"\n" &
    "service {\n  exec \"" & exec & "\"\n}\n")

# ---------------------------------------------------------------------------
# Daemon and clients

type Daemon = object
  process: Process
  mode: string

proc socketPath(mode: string): string =
  if mode == "system": fixture / "jumpstart.sock"
  else: fixture / "home/data/jumpstart.sock"

proc daemonEnv(mode: string; extra: openArray[(string, string)] = []): StringTableRef =
  result = newStringTable(modeCaseSensitive)
  for key, value in envPairs(): result[key] = value
  result["JUMPSTART_TEST_ROOT"] = fixture
  result["JUMPSTART_TEST_MODE"] = mode
  result["JUMPSTART_TEST_RUNNER"] = runnerBin
  result["JUMPSTART_TEST_DEBUG"] = "1"
  if testCgroup.len > 0 and mode == "system": result["JUMPSTART_TEST_CGROUP"] = testCgroup
  for (key, value) in extra: result[key] = value

proc canConnect(path: string): bool =
  try:
    let s = newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM, Protocol.IPPROTO_IP)
    defer: s.close()
    s.connectUnix(path)
    true
  except CatchableError: false

proc logText(mode: string): string =
  let path = if mode == "system": fixture / "log" else: fixture / "home/state/jumpstart.log"
  try: readFile(path) except CatchableError: ""

proc startDaemon(mode = "system"; extra: openArray[(string, string)] = []): Daemon =
  let p = startProcess(daemonBin, workingDir = fixture, args = [],
    env = daemonEnv(mode, extra), options = {poStdErrToStdOut})
  result = Daemon(process: p, mode: mode)
  daemons.add p
  let deadline = epochTime() + 15
  while epochTime() < deadline:
    if canConnect(socketPath(mode)): return
    if not p.running:
      echo p.outputStream.readAll()
      raise newException(IOError, "daemon exited early")
    sleep(50)
  raise newException(IOError, "daemon socket did not appear")

proc stop(d: var Daemon): int =
  if d.process.running:
    discard posix.kill(Pid(d.process.processID), SIGTERM)
  let deadline = epochTime() + 30
  while d.process.running and epochTime() < deadline: sleep(50)
  if d.process.running:
    discard posix.kill(Pid(d.process.processID), SIGKILL)
  result = d.process.waitForExit()
  d.process.close()

proc jumpctl(mode: string; args: varargs[string]): tuple[output: string; code: int] =
  var cmd = "JUMPCTL_TEST_ROOT=" & quoteShell(fixture) & " JUMPCTL_TEST_MODE=" & mode &
    " " & quoteShell(jumpctlBin)
  for arg in args: cmd.add " " & quoteShell(arg)
  let (output, code) = execCmdEx(cmd)
  (output.strip, code)

type Reply = object
  events: seq[JsonNode]
  response: JsonNode

proc connect(mode: string): Socket =
  result = newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM, Protocol.IPPROTO_IP)
  result.connectUnix(socketPath(mode))

proc send(s: Socket; body: JsonNode) =
  var request = %*{"client": {"name": "e2e", "version": "2.0.0"}}
  for key, value in body: request[key] = value
  s.send($request & "\n")

proc receive(s: Socket; timeoutMs = 20_000): Reply =
  while true:
    let line = s.recvLine(timeout = timeoutMs)
    if line.len == 0: raise newException(IOError, "connection closed")
    let node = parseJson(line)
    if node{"type"}.getStr == "event": result.events.add node
    else:
      result.response = node
      return

proc raw(mode: string; body: JsonNode; timeoutMs = 20_000): JsonNode =
  let s = connect(mode)
  defer: s.close()
  s.send(body)
  s.receive(timeoutMs).response

proc ok(r: JsonNode): bool = r{"status"}.getStr == "ok"
proc code(r: JsonNode): string = r{"error"}{"code"}.getStr
proc coreOf(r: JsonNode): string =
  if r.ok: r{"core"}.getStr else: r{"error"}{"core"}.getStr

proc service(name, action: string; args: JsonNode = nil): JsonNode =
  result = %*{"service": {"name": name, "action": action}}
  if not args.isNil: result["service"]["args"] = args

proc coreState(mode, name: string): JsonNode =
  let r = raw(mode, %*{"core": {"action": "status", "name": name}})
  if not r.ok: return r
  r["result"]["cores"][0]

proc waitFor(cond: proc(): bool; seconds = 15.0): bool =
  let deadline = epochTime() + seconds
  while epochTime() < deadline:
    if cond(): return true
    sleep(50)
  cond()

proc waitLoaded(mode, name: string; seconds = 20.0): bool =
  waitFor(proc(): bool =
    let row = coreState(mode, name)
    row{"state"}.getStr in ["loaded", "failed", "degraded"], seconds)

let stateDir = fixture / "var/cores/demo"

proc pidFrom(path: string): int =
  try: parseInt(readFile(path).strip.splitLines[0]) except CatchableError: 0

proc alive(pid: int): bool =
  ## A zombie still answers kill(2) with 0, so the state is read as well.
  if pid <= 0 or posix.kill(Pid(pid), 0) != 0: return false
  try:
    let stat = readFile("/proc/" & $pid & "/stat")
    return stat[stat.rfind(')') + 2] != 'Z'
  except CatchableError: return false

proc zombieChildren(parent: int): seq[int] =
  ## Exited children of `parent` that nobody reaped.
  for kind, path in walkDir("/proc"):
    let name = lastPathPart(path)
    if kind != pcDir or not name.allCharsInSet(Digits): continue
    try:
      let stat = readFile(path / "stat")
      let fields = stat[stat.rfind(')') + 2 .. ^1].splitWhitespace
      if fields[0] == "Z" and parseInt(fields[1]) == parent: result.add parseInt(name)
    except CatchableError: discard

# ---------------------------------------------------------------------------
# Native serviceHandler (any platform)

suite "daemon: native core and control socket":
  test "socket is 0600 and native start/stop/enable/disable/status output is unchanged":
    resetFixture()
    nativeService("web", "sleep 30", mode = "user")
    var d = startDaemon("user")
    var info: Stat
    check stat(socketPath("user").cstring, info) == 0
    check (info.st_mode and Mode(0o777)) == Mode(0o600)
    check jumpctl("user", "start", "web") == ("jumpstart: started unit web", 0)
    check jumpctl("user", "status", "web") ==
      ("jumpstart: unit is reporting status as 'running'", 0)
    # §14.3 legacy suffix: `web.service` still names the native unit.
    check jumpctl("user", "status", "web.service").output ==
      "jumpstart: unit is reporting status as 'running'"
    check jumpctl("user", "stop", "web") == ("jumpstart: stopped unit web", 0)
    check jumpctl("user", "enable", "web") == ("jumpstart: enabled unit web", 0)
    check jumpctl("user", "disable", "web") == ("jumpstart: disabled unit web", 0)
    let status = raw("user", service("serviceHandler/web", "status"))
    check status.ok
    check status.coreOf == "serviceHandler"
    check stop(d) == 0

  test "kill honours --signal and enable --now starts the unit":
    resetFixture()
    nativeService("web", "sleep 30", mode = "user")
    var d = startDaemon("user")
    check jumpctl("user", "enable", "web", "--now").code == 0
    check jumpctl("user", "status", "web").output.contains("'running'")
    check jumpctl("user", "kill", "web", "--signal", "SIGKILL").code == 0
    check waitFor(proc(): bool = jumpctl("user", "status", "web").output.contains("137"))
    check jumpctl("user", "disable", "web", "--now").code == 0
    check stop(d) == 0

  test "peer credentials of another UID are rejected with E_PERMISSION":
    resetFixture()
    var d = startDaemon("user", [("JUMPSTART_TEST_TRUSTED_UID", $(int(getuid()) + 4242))])
    let r = raw("user", %*{"core": {"action": "status"}})
    check r.code == "E_PERMISSION"
    check stop(d) == 0

  test "env store: set, unset, import and list":
    resetFixture()
    var d = startDaemon("user")
    check raw("user", %*{"env": {"action": "set", "vars": {"A": "1", "B": "2"}}}).ok
    check raw("user", %*{"env": {"action": "unset", "vars": {"B": nil}}}).ok
    let imported = raw("user", %*{"env": {"action": "import", "vars": {"C": "3", "D": nil}}})
    check imported.ok
    check imported["result"]["skipped"] == %["D"]
    check raw("user", %*{"env": {"action": "list"}})["result"] ==
      %*{"vars": {"A": "1", "C": "3"}}
    check raw("user", %*{"env": {"action": "set", "vars": {"HOME": "/x"}}}).code == "E_USAGE"
    check stop(d) == 0

  test "framing: oversized and malformed lines are rejected":
    resetFixture()
    var d = startDaemon("user")
    let s = connect("user")
    s.send("{not json}\n")
    let line = s.recvLine(timeout = 5000)
    s.close()
    check parseJson(line){"error"}{"code"}.getStr == "E_PROTOCOL"
    let big = connect("user")
    var data = repeat('x', 1_100_000) & "\n"
    var offset = 0
    while offset < data.len:
      # The daemon answers and closes after 1 MiB; stop at the first error.
      let n = big.send(addr data[offset], min(65536, data.len - offset))
      if n <= 0: break
      offset += n
    check parseJson(big.recvLine(timeout = 5000)){"error"}{"code"}.getStr == "E_PROTOCOL"
    big.close()
    check stop(d) == 0

  test "user-mode shutdown via SIGTERM stops units and removes the socket":
    resetFixture()
    nativeService("web", "sleep 30", mode = "user")
    var d = startDaemon("user")
    check jumpctl("user", "start", "web").code == 0
    var pid = 0
    try: pid = parseInt(readFile(fixture / "home/runtime/serviceHandler/web/pid").strip)
    except CatchableError: discard
    check stop(d) == 0
    check not fileExists(socketPath("user"))
    if pid > 0: check posix.kill(Pid(pid), 0) != 0
    check logText("user").contains("shutdown requested")

# ---------------------------------------------------------------------------
# Extension cores (Linux, root, cgroup v2)

template extensionTest(name: string; body: untyped) =
  test name:
    if not extensionCapable: skip()
    else:
      body


const KernelStateAdapter = """#!/bin/sh
# A oneshot adapter for the kernel-state tests: `-.mount` and `usr.swap` are
# always active; `web.service` is active; `reload.service` is reloading.
read -r hello <&3
printf '%s\n' '{"type":"hello","protocol":"jumpstart-core/1","role":"adapter","operations":["unit.list","unit.resolve","unit.activate","unit.deactivate","mount.status","swap.status","service.status"]}' >&4
read -r request <&3
id=$(printf '%s' "$request" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
reply() { printf '{"type":"response","id":"%s","status":"ok","result":%s}\n' "$id" "$1" >&4; }
st="$JUMPSTART_CORE_STATE_DIR"
case "$JUMPSTART_OP" in
  unit.list)
    base='{"name":"-.mount","subsystem":"mount","enablement":"static"},{"name":"usr.swap","subsystem":"swap","enablement":"static"}'
    case "$JUMPSTART_CORE_NAME" in
      kmixed) reply "{\"units\":[$base,{\"name\":\"web.service\",\"subsystem\":\"service\",\"enablement\":\"enabled\"}]}" ;;
      kreload) reply "{\"units\":[$base,{\"name\":\"reload.service\",\"subsystem\":\"service\",\"enablement\":\"enabled\"}]}" ;;
      *) reply "{\"units\":[$base]}" ;;
    esac ;;
  unit.resolve)
    n="$JUMPSTART_ARG_NAME"
    case "$n" in
      *.mount) reply "{\"owned\":true,\"name\":\"$n\",\"subsystem\":\"mount\"}" ;;
      *.swap) reply "{\"owned\":true,\"name\":\"$n\",\"subsystem\":\"swap\"}" ;;
      web.service|reload.service) reply "{\"owned\":true,\"name\":\"$n\",\"subsystem\":\"service\"}" ;;
      *) reply '{"owned":false,"name":"","subsystem":""}' ;;
    esac ;;
  unit.activate) reply '{"started":0,"failed":[]}' ;;
  unit.deactivate) touch "$st/deactivated"; reply '{"stopped":0,"failed":[]}' ;;
  mount.status)
    reply '{"state":"active","detail":"sub=mounted","enablement":"static","source":"/dev/vda1","target":"/","fstype":"ext4","since":"2026-10-17T08:00:00Z","substate":"mounted"}' ;;
  swap.status)
    reply '{"state":"active","detail":"","enablement":"static","device":"/dev/vda2"}' ;;
  service.status)
    case "$JUMPSTART_UNIT" in
      reload.service) reply '{"state":"reloading","detail":"sub=reload","enablement":"enabled","since":"2026-10-17T08:00:01Z","substate":"reload","result":"success"}' ;;
      *) reply '{"state":"active","detail":"","enablement":"enabled"}' ;;
    esac ;;
esac
"""

proc kernelStateCore(name: string) =
  ## A core (activation "core") whose only guaranteed units are kernel state.
  var text = header(name, ["core", "unit", "mount", "swap", "service"], "core") & verifyOp(true)
  let implemented = ["unit.list", "unit.resolve", "unit.activate", "unit.deactivate",
    "mount.status", "swap.status", "service.status"]
  for op in implemented:
    let readOnly = op in ["unit.list", "unit.resolve", "mount.status", "swap.status",
                          "service.status"]
    text.add "  - name: \"" & op & "\"\n    backend: \"exec\"\n    options:\n" &
      "      executable: \"bin/adapter\"\n      mode: \"oneshot\"\n      timeout: \"30s\"\n" &
      (if readOnly: "      sandbox: true\n      working_directory: \"/tmp\"\n" else: "")
  for sub in ["core", "unit", "mount", "swap", "service"]:
    for spec in operationsForSubsystem(CurrentManifestVersion, sub):
      if spec.name notin implemented and spec.name != "core.verify":
        text.add "  - name: \"" & spec.name & "\"\n    backend: \"unsupported\"\n"
  text.add "init {\n  print \"init\"\n}\n"
  let dir = fixture / "lib/cores" / name
  writeText(dir / "init.kg", text)
  writeText(dir / "bin/adapter", KernelStateAdapter, executable = true)
  writeText(dir / "bin/verify", VerifyScript, executable = true)
  tidy(dir)

suite "daemon: extension cores":
  extensionTest "qualified and unqualified routing, owning core in replies, custom env":
    resetFixture()
    demoCore()
    enable(["demo", "serviceHandler"])
    var d = startDaemon()
    check waitLoaded("system", "demo")
    check coreState("system", "demo"){"state"}.getStr == "loaded"
    # Qualified: unit.resolve receives UNIT, not CORE/UNIT.
    let q = raw("system", service("demo/alpha", "start"))
    check q.ok
    check q.coreOf == "demo"
    check fileExists(stateDir / "alpha.service.active")
    let u = raw("system", service("beta", "start"))
    check u.ok
    check u.coreOf == "demo"
    check raw("system", service("demo/missing", "start")).code == "E_NOT_FOUND"
    # kill --signal and enable --now reach the backend as typed arguments.
    check raw("system", service("alpha", "kill", %*{"signal": "SIGUSR1"})).ok
    check readFile(stateDir / "alpha.service.killed") == "SIGUSR1"
    check raw("system", service("alpha", "kill")).ok
    check readFile(stateDir / "alpha.service.killed") == "SIGTERM"
    check raw("system", %*{"service": {"name": "alpha", "action": "enable", "now": "true"}}).ok
    check readFile(stateDir / "alpha.service.enabled") == "true"
    check raw("system", service("alpha", "disable")).ok
    check readFile(stateDir / "alpha.service.disabled") == "false"
    # §16.1 custom backends see the JUMPSTART_* variables.
    let st = raw("system", service("demo/alpha", "status"))
    check st.ok
    check st["result"]["detail"].getStr == "demo|service.status|alpha.service|system"
    # Activation (asCore) ran once loaded.
    check fileExists(stateDir / "activated")
    # Fan-out without --core.
    let listed = raw("system", %*{"op": {"core": "", "name": "unit.list"}})
    check listed.ok
    var cores: seq[string]
    for item in listed["result"]["units"]: cores.add item["core"].getStr
    check "demo" in cores and "serviceHandler" in cores
    let loaded = raw("system", %*{"op": {"core": "", "name": "unit.load"}})
    check loaded.ok
    check loaded["result"]["loaded"].getInt >= 2
    # Core actions are limited to the five of §21.2.
    check raw("system", %*{"core": {"action": "enable", "name": "demo"}}).code == "E_USAGE"
    let sandboxed = raw("system", %*{"op": {"core": "demo", "name": "core.verify"}})
    check sandboxed.ok or sandboxed.code == "E_SANDBOX"
    check stop(d) == 0
    check fileExists(stateDir / "deactivated")

  extensionTest "requests wait while a core loads; its init can call jumpctl":
    resetFixture()
    let marker = fixture / "init-jumpctl.txt"
    demoCore(initBody = "  local out = \"${exec(\\\"sleep 2; JUMPCTL_TEST_ROOT=" & fixture &
      " JUMPCTL_TEST_MODE=system " & jumpctlBin & " units list > " & marker &
      " 2>&1; echo done\\\").output()}\"\n")
    enable(["demo", "serviceHandler"])
    var d = startDaemon()
    let started = epochTime()
    let r = raw("system", service("alpha", "start"), timeoutMs = 60_000)
    check r.ok
    check r.coreOf == "demo"
    check epochTime() - started < 30
    check fileExists(marker)
    check coreState("system", "demo"){"state"}.getStr == "loaded"
    check stop(d) == 0

  extensionTest "E_LIMIT for reads, queueing for mutating operations":
    resetFixture()
    demoCore()
    enable(["demo"])
    var d = startDaemon()
    check waitLoaded("system", "demo")
    var sockets: seq[Socket]
    for i in 0 ..< 70:
      let s = connect("system")
      s.send(service("demo/v" & $i, "validate"))
      sockets.add s
    var okCount, limited = 0
    for s in sockets:
      let r = s.receive(30_000).response
      if r.ok: inc okCount
      elif r.code == "E_LIMIT": inc limited
      s.close()
    check limited >= 1
    check okCount >= 60
    sockets.setLen(0)
    let t0 = epochTime()
    for i in 0 ..< 20:
      let s = connect("system")
      s.send(service("demo/r" & $i, "restart", %*{"delay": "1"}))
      sockets.add s
    var restarted = 0
    for s in sockets:
      if s.receive(60_000).response.ok: inc restarted
      s.close()
    check restarted == 20
    check epochTime() - t0 >= 1.8      # 16 in flight, 4 queued behind them
    check stop(d) == 0

  extensionTest "log.follow streams events and does not block stop; closing cancels":
    resetFixture()
    demoCore()
    enable(["demo"])
    var d = startDaemon()
    check waitLoaded("system", "demo")
    let follower = connect("system")
    follower.send(service("demo/alpha", "log-follow"))
    let first = parseJson(follower.recvLine(timeout = 10_000))
    check first{"type"}.getStr == "event"
    check first{"event"}.getStr == "entry"
    let t0 = epochTime()
    check raw("system", service("demo/alpha", "stop")).ok
    check epochTime() - t0 < 5
    follower.close()
    # Closing a connection cancels its request: the restart never finishes.
    let slow = connect("system")
    slow.send(service("demo/slowx", "restart", %*{"delay": "3"}))
    sleep(500)
    slow.close()
    sleep(4000)
    check not fileExists(stateDir / "slowx.service.restarted")
    check stop(d) == 0

  extensionTest "E_STATE falls back to serviceHandler only":
    resetFixture()
    demoCore()
    enable(["demo", "serviceHandler"])
    writeFile(fixture / "etc/cores/enabled/demo", "not empty")
    var d = startDaemon()
    check waitLoaded("system", "serviceHandler")
    let r = raw("system", %*{"core": {"action": "status"}})
    check r.ok
    check r["result"]["state_error"]["code"].getStr == "E_STATE"
    check coreState("system", "demo"){"state"}.getStr == "unloaded"
    check stop(d) == 0

  extensionTest "a failed init rolls back fully and fails its dependents":
    resetFixture()
    plainCore("broken", "  fail E_INIT \"boom\"\n")
    plainCore("dependent", "  print \"init\"\n", delegateTo = "broken")
    enable(["broken", "dependent"])
    var d = startDaemon()
    check waitLoaded("system", "broken")
    check waitLoaded("system", "dependent")
    let broken = coreState("system", "broken")
    check broken{"state"}.getStr == "failed"
    check broken{"error"}{"code"}.getStr == "E_INIT"
    let dependent = coreState("system", "dependent")
    check dependent{"state"}.getStr == "failed"
    check dependent{"error"}{"code"}.getStr == "E_DELEGATION"
    check not dirExists(fixture / "run/cores/broken")
    check not dirExists(testCgroup / "jumpstart/cores/broken")
    check stop(d) == 0

  extensionTest "reload clears staleness; unload and load":
    resetFixture()
    demoCore()
    enable(["demo", "serviceHandler"])
    var d = startDaemon()
    check waitLoaded("system", "demo")
    check coreState("system", "demo"){"stale"}.getBool == false
    sleep(1100)
    demoCore(initBody = "  print \"changed\"\n")
    check coreState("system", "demo"){"stale"}.getBool == true
    # The demo units report active, so a plain reload is refused (§20.4).
    check raw("system", %*{"core": {"action": "reload", "name": "demo"}}, 60_000).code == "E_BUSY"
    check raw("system", %*{"core": {"action": "reload", "name": "demo",
      "stop_units": true}}, 60_000).ok
    check coreState("system", "demo"){"stale"}.getBool == false
    check raw("system", %*{"core": {"action": "unload", "name": "demo",
      "stop_units": true}}, 60_000).ok
    check coreState("system", "demo"){"state"}.getStr == "unloaded"
    check not dirExists(testCgroup / "jumpstart/cores/demo")
    check raw("system", %*{"core": {"action": "load", "name": "demo"}}, 60_000).ok
    check coreState("system", "demo"){"state"}.getStr == "loaded"
    let loadedRows = raw("system", %*{"core": {"action": "list-loaded"}})
    check loadedRows["result"]["cores"][^1]["name"].getStr == "demo"
    check stop(d) == 0

suite "daemon: robustness":
  test "the loop survives an injected fault and keeps serving":
    resetFixture()
    nativeService("web", "sleep 30", mode = "user")
    let faultFile = fixture / "fault"
    var d = startDaemon("user", [("JUMPSTART_TEST_FAULT_FILE", faultFile)])
    check jumpctl("user", "status", "web").code == 0
    writeFile(faultFile, "")
    check waitFor(proc(): bool = not fileExists(faultFile), 10)   # the hook ran
    check waitFor(proc(): bool = logText("user").contains("event loop fault"), 10)
    check d.process.running
    check jumpctl("user", "start", "web") == ("jumpstart: started unit web", 0)
    check stop(d) == 0

  test "stopping one unit does not wait behind a long stop of another (§11.6)":
    resetFixture()
    writeText(fixture / "stubborn.sh",
      "#!/bin/sh\ntrap '' TERM\nwhile :; do sleep 1; done\n", executable = true)
    nativeService("stubborn", fixture / "stubborn.sh", mode = "user")
    nativeService("quick", "sleep 30", mode = "user")
    var d = startDaemon("user")
    check jumpctl("user", "start", "stubborn").code == 0
    check jumpctl("user", "start", "quick").code == 0
    let slow = connect("user")          # ignores SIGTERM: the stop takes ~10 s
    slow.send(service("stubborn", "stop"))
    sleep(500)
    let t0 = epochTime()
    check raw("user", service("quick", "stop")).ok
    check epochTime() - t0 < 5
    check slow.receive(40_000).response.ok
    slow.close()
    check stop(d) == 0

  test "daemon unaffected by a client flooding after its request":
    resetFixture()
    nativeService("web", "sleep 30", mode = "user")
    var d = startDaemon("user")
    let s = connect("user")
    s.send(service("web", "status"))
    let flood = repeat('x', 65536)
    for i in 0 ..< 64:
      if s.send(unsafeAddr flood[0], flood.len) <= 0: break
    s.close()
    check jumpctl("user", "status", "web").code == 0
    check stop(d) == 0

suite "daemon: system boot without persistent storage":
  extensionTest "with mount_fstab = false nothing persistent is written until filesystems are ready":
    resetFixture()
    demoCore(name = "gate", supervisorScript = ReadySupervisor)
    enable(["gate"])
    let fstab = fixture / "fstab"
    let mountinfo = fixture / "mountinfo"
    # /var is in fstab but not mounted yet: nothing may be created below it.
    writeFile(fstab, "tmpfs " & fixture / "var" & " tmpfs defaults 0 0\n")
    writeFile(mountinfo, "1 0 0:1 / / rw - rootfs rootfs rw\n")
    var d = startDaemon("system", [("JUMPSTART_TEST_FS_READY", "0"),
      ("JUMPSTART_TEST_FSTAB", fstab), ("JUMPSTART_TEST_MOUNTINFO", mountinfo)])
    check waitLoaded("system", "gate")
    check coreState("system", "gate"){"state"}.getStr == "loaded"
    let gateState = fixture / "var/cores/gate"
    check not dirExists(gateState)               # no state directory yet
    check not fileExists(fixture / "log")        # the log is buffered in memory
    # The core reports filesystems-ready (§17.5): the buffered log is flushed
    # in order and the report that reached it is logged with its core.
    writeFile(fixture / "ready-flag", "")
    check waitFor(proc(): bool = fileExists(fixture / "log"), 15)
    let log = logText("system")
    check log.contains("filesystems are ready (reported by gate)")
    check log.find("Initializing") < log.find("filesystems are ready")
    # ... but nothing is created below /var, which a later mount would shadow.
    check not dirExists(gateState)
    check logText("system").contains("not mounted yet")
    # Once it is mounted, the next request to the core creates the directory.
    writeFile(mountinfo, "1 0 0:1 / / rw - rootfs rootfs rw\n" &
      "2 1 0:2 / " & fixture / "var" & " rw - tmpfs tmpfs rw\n")
    check raw("system", service("gate/alpha", "start")).ok
    check dirExists(gateState)
    writeFile(fixture / "activate-flag", "")      # a later activation changes nothing
    check stop(d) == 0

  extensionTest "filesystems become ready once every startup core finished activation":
    resetFixture()
    demoCore(name = "gate")
    enable(["gate"])
    writeFile(fixture / "activate-flag", "")
    var d = startDaemon("system", [("JUMPSTART_TEST_FS_READY", "0")])
    check waitFor(proc(): bool = dirExists(fixture / "var/cores/gate"), 20)
    check waitFor(proc(): bool = logText("system").contains("filesystems are ready"), 20)
    check not logText("system").contains("reported by")
    check stop(d) == 0

  extensionTest "with mount_fstab = false the wait for filesystems is bounded and logged":
    # The gate core's activation never ends and nobody reports: the daemon
    # must not buffer its log and withhold state directories forever (§20.2).
    resetFixture()
    demoCore(name = "gate")
    enable(["gate"])
    var d = startDaemon("system", [("JUMPSTART_TEST_FS_READY", "0"),
      ("JUMPSTART_TEST_FS_WAIT_MS", "2500")])
    check waitLoaded("system", "gate")
    check not logText("system").contains("filesystems are ready")
    check waitFor(proc(): bool = logText("system").contains("filesystems are ready"), 20)
    let log = logText("system")
    check log.contains("assuming the filesystems are ready")
    check not log.contains("reported by")
    check waitFor(proc(): bool = dirExists(fixture / "var/cores/gate"), 20)
    writeFile(fixture / "activate-flag", "")
    check stop(d) == 0

suite "daemon: process ownership and shutdown":
  extensionTest "orphans are reaped and logged; no zombie is left":
    resetFixture()
    demoCore()
    enable(["demo"])
    var d = startDaemon()
    check waitLoaded("system", "demo")
    check raw("system", service("demo/orphan", "start")).ok
    check waitFor(proc(): bool = logText("system").contains("reaped unowned child"), 10)
    sleep(300)
    check zombieChildren(d.process.processID).len == 0
    check stop(d) == 0

  extensionTest "unload kills what the core left behind (cgroup kill, §15.1 rule 5)":
    resetFixture()
    demoCore()
    enable(["demo", "serviceHandler"])
    var d = startDaemon()
    check waitLoaded("system", "demo")
    check raw("system", service("demo/leak", "start")).ok
    check raw("system", service("demo/held", "start")).ok
    let leak = pidFrom(stateDir / "leak.pid")
    let held = pidFrom(stateDir / "held.pid")
    check leak > 0 and held > 0
    check alive(leak) and alive(held)
    # Without --stop-units the busy core refuses (§20.4), and nothing is touched.
    check raw("system", %*{"core": {"action": "unload", "name": "demo"}}, 60_000).code == "E_BUSY"
    check alive(leak) and alive(held)
    check coreState("system", "demo"){"state"}.getStr == "loaded"
    check raw("system", %*{"core": {"action": "unload", "name": "demo",
      "stop_units": true}}, 60_000).ok
    check waitFor(proc(): bool = not alive(leak) and not alive(held), 10)
    check not dirExists(testCgroup / "jumpstart/cores/demo")
    check zombieChildren(d.process.processID).len == 0
    check stop(d) == 0

  extensionTest "kernel-state units do not make a core busy; status extras and reloading pass through (§20.4, §12.11)":
    resetFixture()
    kernelStateCore("konly")
    kernelStateCore("kmixed")
    kernelStateCore("kreload")
    enable(["konly", "kmixed", "kreload", "serviceHandler"])
    var d = startDaemon()
    check waitLoaded("system", "konly")
    check waitLoaded("system", "kmixed")
    check waitLoaded("system", "kreload")
    # A dash name routes: qualified and unqualified, with the extension fields.
    check raw("system", service("kmixed/usr.swap", "status")).ok
    for name in ["konly/-.mount", "kmixed/-.mount"]:
      let r = raw("system", service(name, "status"))
      check r.ok
      check r["result"]["state"].getStr == "active"
      check r["result"]["since"].getStr == "2026-10-17T08:00:00Z"
      check r["result"]["substate"].getStr == "mounted"
    # Unqualified -.mount is claimed by every one of these cores: ambiguous.
    let ambiguous = raw("system", service("-.mount", "status"))
    check ambiguous.code == "E_AMBIGUOUS"
    check "konly/-.mount" in ambiguous{"error"}{"message"}.getStr
    # `reloading` is a valid state and a core counts as busy while it reloads.
    let reloading = raw("system", service("kreload/reload.service", "status"))
    check reloading.ok
    check reloading["result"]["state"].getStr == "reloading"
    check reloading["result"]["result"].getStr == "success"
    check raw("system", %*{"core": {"action": "unload", "name": "kreload"}}, 60_000).code == "E_BUSY"
    # Only active mount and swap units: not busy, unload succeeds without --stop-units.
    check raw("system", %*{"core": {"action": "unload", "name": "konly"}}, 60_000).ok
    check coreState("system", "konly"){"state"}.getStr == "unloaded"
    check not dirExists(testCgroup / "jumpstart/cores/konly")
    # A service next to them makes the core busy, and only the service is named.
    let busy = raw("system", %*{"core": {"action": "unload", "name": "kmixed"}}, 60_000)
    check busy.code == "E_BUSY"
    let message = busy{"error"}{"message"}.getStr
    check "web.service" in message
    check "-.mount" notin message and "usr.swap" notin message
    check coreState("system", "kmixed"){"state"}.getStr == "loaded"
    # With --stop-units, unit.deactivate runs once and the unload completes (the
    # core leaves its mount and swap units active).
    check raw("system", %*{"core": {"action": "unload", "name": "kmixed",
      "stop_units": true}}, 60_000).ok
    check coreState("system", "kmixed"){"state"}.getStr == "unloaded"
    check fileExists(fixture / "var/cores/kmixed/deactivated")
    # An unloaded core that is known to own the name still answers for it (§14.3).
    let unloaded = raw("system", service("-.mount", "status"))
    check unloaded.code == "E_CORE_UNLOADED"
    check stop(d) == 0

  extensionTest "an unqualified unit name that begins with '-' routes to its only owner":
    resetFixture()
    kernelStateCore("kreload")
    enable(["kreload", "serviceHandler"])
    var d = startDaemon()
    check waitLoaded("system", "kreload")
    for name in ["-.mount", "kreload/-.mount"]:
      let r = raw("system", service(name, "status"))
      check r.ok
      check r.coreOf == "kreload"
      check r["result"]["substate"].getStr == "mounted"
    check raw("system", service("-.nothing", "status")).code == "E_NOT_FOUND"
    check stop(d) == 0

  extensionTest "a supervisor that exits degrades its core; reload recovers it":
    resetFixture()
    demoCore(supervisorScript = IdleSupervisor)
    enable(["demo", "serviceHandler"])
    var d = startDaemon()
    check waitLoaded("system", "demo")
    check coreState("system", "demo"){"state"}.getStr == "loaded"
    let supervisor = pidFrom(fixture / "run/cores/demo/supervisor.pid")
    check supervisor > 0
    check posix.kill(Pid(supervisor), SIGKILL) == 0
    check waitFor(proc(): bool = coreState("system", "demo"){"state"}.getStr == "degraded", 10)
    check raw("system", service("demo/alpha", "start")).code == "E_DEGRADED"
    # Recovery needs no answer from the broken component (§20.7).
    check raw("system", %*{"core": {"action": "reload", "name": "demo",
      "stop_units": true}}, 60_000).ok
    check coreState("system", "demo"){"state"}.getStr == "loaded"
    check raw("system", service("demo/alpha", "start")).ok
    check stop(d) == 0

  extensionTest "a service outlives an adapter restart; the adapter restarts lazily":
    resetFixture()
    demoCore(persistent = true)
    enable(["demo", "serviceHandler"])
    var d = startDaemon()
    check waitLoaded("system", "demo")
    check coreState("system", "demo"){"state"}.getStr == "loaded"
    check raw("system", service("demo/alpha", "start")).ok
    let service = pidFrom(stateDir / "alpha.service.pid")
    check service > 0 and alive(service)
    let adapter = pidFrom(stateDir / "adapter.pids")
    check adapter > 0
    check posix.kill(Pid(adapter), SIGKILL) == 0
    check waitFor(proc(): bool = not alive(adapter), 10)
    check alive(service)                      # the unit process is not the adapter's child
    # The next request restarts the adapter (§17.6) and is answered.
    var restarted = false
    check waitFor(proc(): bool =
      let r = raw("system", %*{"op": {"core": "demo", "name": "unit.list"}})
      restarted = r.ok
      restarted, 20)
    check readFile(stateDir / "adapter.pids").strip.splitLines.len == 2
    check coreState("system", "demo"){"state"}.getStr == "loaded"
    check alive(service)
    check raw("system", %*{"core": {"action": "unload", "name": "demo",
      "stop_units": true}}, 60_000).ok
    check waitFor(proc(): bool = not alive(service), 10)
    check stop(d) == 0

  extensionTest "a request from a core's init to a core queued behind it does not wait for it":
    resetFixture()
    let marker = fixture / "init-queued.txt"
    demoCore(name = "a1", initBody = "  local out = \"${exec(\\\"JUMPCTL_TEST_ROOT=" & fixture &
      " JUMPCTL_TEST_MODE=system " & jumpctlBin & " status b1/alpha > " & marker &
      " 2>&1; echo done\\\").output()}\"\n")
    demoCore(name = "b1")
    enable(["a1", "b1"])
    var d = startDaemon()
    let started = epochTime()
    check waitLoaded("system", "a1")
    check waitLoaded("system", "b1")
    check epochTime() - started < 40            # not the 60 s of init's timeout
    check coreState("system", "a1"){"state"}.getStr == "loaded"
    check coreState("system", "b1"){"state"}.getStr == "loaded"
    check readFile(marker).contains("E_CORE_UNLOADED")
    check stop(d) == 0

  extensionTest "system shutdown unloads cores in the reverse of load order (§20.8)":
    resetFixture()
    plainCore("base", "  print \"init\"\n")
    plainCore("top", "  print \"init\"\n", delegateTo = "base")
    enable(["base", "top", "serviceHandler"])
    var d = startDaemon()
    check waitLoaded("system", "base")
    check waitLoaded("system", "top")
    check stop(d) == 0
    let log = logText("system")
    check log.find("shutdown requested") >= 0
    let top = log.find("[core:top] unload started")
    let base = log.find("[core:base] unload started")
    check top > log.find("shutdown requested")
    check base > top                       # delegating cores unload first
    check not dirExists(testCgroup / "jumpstart/cores/top")

  extensionTest "a user daemon's shutdown stops within 25 seconds even if a core hangs (§20.9)":
    resetFixture()
    demoCore()
    writeText(fixture / "lib/cores/demo/bin/hang-deactivate", "")
    tidy(fixture / "lib/cores/demo")
    enable(["demo"], mode = "user")
    var d = startDaemon("user", [("JUMPSTART_TEST_CGROUP", testCgroup)])
    check waitLoaded("user", "demo")
    check coreState("user", "demo"){"state"}.getStr == "loaded"
    let started = epochTime()
    check stop(d) == 0
    check epochTime() - started < 26
    check logText("user").contains("shutdown requested")

if testCgroup.len > 0 and dirExists(testCgroup):
  discard execCmdEx("find " & quoteShell(testCgroup) & " -depth -type d -exec rmdir {} +")
