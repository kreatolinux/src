## serviceHandler native backend: resolve and every native operation, with
## real processes run through the spawn layer and the central reaper. All
## roots are temporary directories.
import std/[json, os, posix, sequtils, strutils, times, unittest]
import ../../jumpstart/serviceHandler/native_bridge
import ../../jumpstart/cores/lifecycle/routing
import jumpstartcore/[cgroups, errors, reaper]

proc tempRoot(label: string): string =
  result = getTempDir() / ("jumpstart-native-bridge-" & label & "-" &
    $getCurrentProcessId() & "-" & $int(epochTime() * 1000))
  createDir(result / "etc")

proc unitFile(root, name, body: string) =
  writeFile(root / "etc" / (name & ".kg"), body)

proc service(root, name, exec: string; kind = "simple"; extra = "";
             body = "") =
  unitFile(root, name, "description: \"" & name & "\"\ntype: \"" & kind &
    "\"\n" & extra & "service {\n  exec \"" & exec & "\"\n" & body & "}\n")

proc target(root, name: string; wants: seq[string]) =
  var text = "description: \"" & name & "\"\ntype: \"target\"\n"
  if wants.len > 0:
    text.add "wants:\n"
    for item in wants: text.add "  - \"" & item & "\"\n"
  unitFile(root, name, text)

proc newBridge(root: string): NativeBridge =
  let ctx = newNativeContext(root / "etc", root / "run", newReaper(),
    socketPath = root / "missing.sock", stopTimeoutMs = 3000)
  newNativeBridge(ctx, resetRuntime = true)

proc codeOf(body: proc()): string =
  try: body()
  except CoreError as e: return errorName(e.code)
  "no error"

proc status(bridge: NativeBridge; unit: string): JsonNode =
  let reply = bridge.resolve(unit)
  bridge.dispatch(reply.subsystem & ".status", reply.canonicalName)

proc settle(bridge: NativeBridge; unit, state: string; timeoutMs = 5000): bool =
  ## Pump the reaper until the unit reports `state`.
  var waited = 0
  while waited <= timeoutMs:
    bridge.ctx.pump()
    if bridge.status(unit)["state"].getStr == state: return true
    sleep(10); waited += 10
  false

proc cleanup(bridge: NativeBridge; root: string) =
  discard bridge.deactivate()
  removeDir(root)

suite "native unit.resolve":
  test "subsystems follow the decfile and multi resolves to target":
    let root = tempRoot("resolve")
    service(root, "web", "sleep 30")
    target(root, "multi-user", @["web"])
    unitFile(root, "data", "description: \"d\"\ntype: \"mount\"\nmount {\n  from \"tmpfs\"\n  to \"/tmp/x\"\n  fstype \"tmpfs\"\n}\n")
    unitFile(root, "tick", "description: \"t\"\ntype: \"timer\"\ntimer {\n  interval 60\n  service \"web\"\n}\n")
    unitFile(root, "stack", "description: \"s\"\ntype: \"multi\"\n" &
      "mount data {\n  from \"tmpfs\"\n  to \"/tmp/y\"\n  fstype \"tmpfs\"\n}\n" &
      "service api {\n  exec \"sleep 30\"\n}\n" &
      "timer sweep {\n  interval 60\n  service \"web\"\n}\n")
    let bridge = newBridge(root)
    defer: bridge.cleanup(root)
    for (name, sub) in [("web", "service"), ("multi-user", "target"),
                        ("data", "mount"), ("tick", "timer"), ("stack", "target"),
                        ("stack::api", "service"), ("stack::data", "mount"),
                        ("stack::sweep", "timer"), ("default", "target")]:
      let reply = bridge.resolve(name)
      check reply.owned
      check reply.canonicalName == name
      check reply.subsystem == sub
      check not reply.legacySuffix
    check not bridge.resolve("missing").owned
    check not bridge.resolve("stack::missing").owned
    check not bridge.resolve("").owned
    # Names that begin with `-` are valid unit names (§14.1) but never native:
    # serviceHandler's own rules are unchanged, so it simply does not own them.
    for name in ["-.mount", "-.slice", "-", "-x"]:
      check not bridge.resolve(name).owned

  test "legacy suffixes are stripped and reported":
    let root = tempRoot("legacy")
    service(root, "web", "sleep 30")
    unitFile(root, "stack", "description: \"s\"\ntype: \"multi\"\nservice api {\n  exec \"sleep 30\"\n}\n")
    service(root, "odd.service", "sleep 30")
    let bridge = newBridge(root)
    defer: bridge.cleanup(root)
    for name in ["web.kg", "web.service", "web.mount", "web.timer"]:
      let reply = bridge.resolve(name)
      check reply.owned and reply.canonicalName == "web" and reply.legacySuffix
    let sub = bridge.resolve("stack.kg::api")
    check sub.owned and sub.canonicalName == "stack::api" and sub.legacySuffix
    check sub.subsystem == "service"
    let exact = bridge.resolve("odd.service")
    check exact.owned and exact.canonicalName == "odd.service" and not exact.legacySuffix
    let builtin = bridge.resolve("default.kg")
    check builtin.owned and builtin.canonicalName == "default" and builtin.legacySuffix
    let result = bridge.dispatch("unit.resolve", "", %*{"name": "web.service"})
    check result == %*{"owned": true, "name": "web", "subsystem": "service"}

  test "decfiles added after load resolve without a reload":
    let root = tempRoot("late")
    let bridge = newBridge(root)
    defer: bridge.cleanup(root)
    check not bridge.resolve("late").owned
    service(root, "late", "sleep 30")
    check bridge.resolve("late").owned

suite "native services":
  test "start, requested stop, start again, and restart":
    let root = tempRoot("lifecycle")
    service(root, "web", "sleep 30")
    let bridge = newBridge(root)
    defer: bridge.cleanup(root)
    check bridge.status("web") == %*{"state": "inactive", "detail": "stopped",
                                     "enablement": "disabled"}
    check bridge.dispatch("service.start", "web") == %*{"state": "active"}
    let running = bridge.status("web")
    check running["state"].getStr == "active"
    check running["detail"].getStr == "running"
    check running["main_pid"].getInt > 1
    check nativeStatusText(running) == "running"
    # Idempotent start.
    check bridge.dispatch("service.start", "web") == %*{"state": "active"}
    check bridge.dispatch("service.stop", "web") == %*{"state": "inactive"}
    let stopped = bridge.status("web")
    check stopped["state"].getStr == "inactive"
    check stopped["exit_code"].getInt == 143
    check nativeStatusText(stopped) == "stopped with an exit code 143"
    check bridge.dispatch("service.stop", "web") == %*{"state": "inactive"}
    # Appendix A: start after stop works.
    check bridge.dispatch("service.start", "web") == %*{"state": "active"}
    let firstPid = bridge.status("web")["main_pid"].getInt
    check bridge.dispatch("service.restart", "web") == %*{"state": "active"}
    check bridge.status("web")["main_pid"].getInt != firstPid

  test "a failure and a signal Jumpstart did not request map to failed":
    let root = tempRoot("failure")
    service(root, "crash", "sh -c 'exit 3'")
    service(root, "victim", "sleep 30")
    let bridge = newBridge(root)
    defer: bridge.cleanup(root)
    discard bridge.dispatch("service.start", "crash")
    check bridge.settle("crash", "failed")
    let crashed = bridge.status("crash")
    check crashed["exit_code"].getInt == 3
    check crashed["detail"].getStr == "stopped with an exit code 3"
    # A crashed service can be started again.
    check bridge.dispatch("service.start", "crash")["state"].getStr in ["active", "failed"]
    discard bridge.dispatch("service.start", "victim")
    check bridge.dispatch("service.kill", "victim", %*{"signal": "TERM"}) == newJObject()
    check bridge.settle("victim", "failed")
    check bridge.status("victim")["exit_code"].getInt == 143

  test "clean exit is inactive and runs execPost":
    let root = tempRoot("clean")
    let marker = root / "post-ran"
    service(root, "once", "true", kind = "oneshot",
            body = "  exec_post \"touch " & marker & "\"\n")
    let bridge = newBridge(root)
    defer: bridge.cleanup(root)
    discard bridge.dispatch("service.start", "once")
    check bridge.settle("once", "inactive")
    var waited = 0
    while not fileExists(marker) and waited < 3000:
      bridge.ctx.pump(); sleep(10); waited += 10
    check fileExists(marker)
    check bridge.status("once")["detail"].getStr == "stopped"
    check not bridge.status("once").hasKey("exit_code")

  test "kill validates signals and requires a running service":
    let root = tempRoot("kill")
    service(root, "web", "sleep 30")
    let bridge = newBridge(root)
    defer: bridge.cleanup(root)
    check codeOf(proc() = discard bridge.dispatch("service.kill", "web",
      %*{"signal": "SIGTERM"})) == "E_UNIT_STATE"
    discard bridge.dispatch("service.start", "web")
    check codeOf(proc() = discard bridge.dispatch("service.kill", "web",
      %*{"signal": "NOPE"})) == "E_USAGE"
    check codeOf(proc() = discard bridge.dispatch("service.kill", "web",
      %*{"signal": "0"})) == "E_USAGE"
    # SIGCONT by number and by name leaves it running.
    discard bridge.dispatch("service.kill", "web", %*{"signal": $int(SIGCONT)})
    discard bridge.dispatch("service.kill", "web", %*{"signal": "SIGCONT"})
    check bridge.status("web")["state"].getStr == "active"

  test "start failures are reported with codes":
    let root = tempRoot("errors")
    service(root, "ghost", "/nonexistent/binary")
    let bridge = newBridge(root)
    defer: bridge.cleanup(root)
    check codeOf(proc() = discard bridge.dispatch("service.start", "ghost")) == "E_BACKEND"
    check bridge.status("ghost")["state"].getStr == "inactive"
    check codeOf(proc() = discard bridge.dispatch("service.start", "missing")) == "E_NOT_FOUND"
    check codeOf(proc() = discard bridge.dispatch("service.reload", "ghost")) == "E_UNSUPPORTED"
    check codeOf(proc() = discard bridge.dispatch("unit.translate", "ghost")) == "E_UNSUPPORTED"
    check codeOf(proc() = discard bridge.dispatch("mount.start", "ghost")) == "E_UNSUPPORTED"

suite "native mounts and timers":
  test "mount status carries its fields; a failed mount stays inactive":
    let root = tempRoot("mount")
    unitFile(root, "data", "description: \"d\"\ntype: \"mount\"\nmount {\n  from \"none\"\n  to \"" &
      root / "mnt" & "\"\n  fstype \"jumpstart-test-nonexistent-fs\"\n}\n")
    let bridge = newBridge(root)
    defer: bridge.cleanup(root)
    check bridge.status("data") == %*{"state": "inactive", "detail": "stopped",
      "source": "none", "target": root / "mnt",
      "fstype": "jumpstart-test-nonexistent-fs", "enablement": "disabled"}
    check codeOf(proc() = discard bridge.dispatch("mount.start", "data")) == "E_BACKEND"
    check bridge.status("data")["state"].getStr == "inactive"
    check bridge.dispatch("mount.stop", "data", %*{"lazy": false}) == %*{"state": "inactive"}
    createDir(root / "run/mounts/data")
    writeFile(root / "run/mounts/data/status", "mounted")
    check bridge.status("data")["state"].getStr == "active"
    check nativeStatusText(bridge.status("data")) == "mounted"

  test "timers arm, report, disarm and re-arm":
    let root = tempRoot("timer")
    service(root, "job", "true", kind = "oneshot")
    unitFile(root, "tick", "description: \"t\"\ntype: \"timer\"\ntimer {\n  interval 3600\n  service \"job\"\n}\n")
    let bridge = newBridge(root)
    defer: bridge.cleanup(root)
    check bridge.dispatch("timer.start", "tick") == %*{"state": "active"}
    # The timer thread writes its state file after `start` returns.
    var armed = bridge.status("tick")
    for _ in 0 ..< 200:
      if armed["detail"].getStr == "running" and armed.hasKey("next_run"): break
      sleep(10)
      armed = bridge.status("tick")
    check armed["detail"].getStr == "running"
    check armed.hasKey("next_run")
    # Stopping runs on the daemon thread and must not wait out the timer
    # thread's one second tick.
    let stopStart = epochTime()
    check bridge.dispatch("timer.stop", "tick") == %*{"state": "inactive"}
    check epochTime() - stopStart < 0.5
    check bridge.status("tick")["detail"].getStr == "stopped"
    check bridge.dispatch("timer.start", "tick") == %*{"state": "active"}

suite "native targets":
  test "target status counts oneshots that exited 0 since the target started":
    let root = tempRoot("oneshot")
    service(root, "setup", "true", kind = "oneshot")
    service(root, "web", "sleep 30")
    target(root, "app", @["setup", "web"])
    target(root, "empty", @[])
    let bridge = newBridge(root)
    defer: bridge.cleanup(root)
    let before = bridge.status("app")
    check before["state"].getStr == "inactive"
    check before["members"] == %*["setup", "web"]
    check nativeStatusText(before) == "stopped"
    discard bridge.dispatch("target.start", "app")
    check bridge.settle("app", "active")
    check bridge.status("app")["detail"].getStr == "2 of 2 members satisfied"
    check nativeStatusText(bridge.status("app")) == "running"
    # A member stopped individually leaves the target activating.
    discard bridge.dispatch("service.stop", "web")
    check bridge.status("app")["state"].getStr == "activating"
    check nativeStatusText(bridge.status("app")) == "starting"
    check bridge.dispatch("target.stop", "app") == %*{"state": "inactive"}
    # A started target with no members is active.
    check bridge.status("empty")["state"].getStr == "inactive"
    check bridge.dispatch("target.start", "empty") == %*{"state": "active"}

  test "a failed member makes the target failed and start partial":
    let root = tempRoot("failedmember")
    service(root, "bad", "sh -c 'exit 1'", kind = "oneshot")
    service(root, "ghost", "/nonexistent/binary")
    target(root, "app", @["bad"])
    target(root, "broken", @["ghost"])
    let bridge = newBridge(root)
    defer: bridge.cleanup(root)
    discard bridge.dispatch("target.start", "app")
    check bridge.settle("app", "failed")
    check codeOf(proc() = discard bridge.dispatch("target.start", "broken")) == "E_PARTIAL"
    check bridge.status("broken")["state"].getStr == "failed"
    # An unknown member makes status failed rather than an error.
    target(root, "dangling", @["absent"])
    check bridge.status("dangling")["state"].getStr == "failed"

  test "starting a target starts static members and their depends closure":
    let root = tempRoot("closure")
    service(root, "network", "sleep 30")
    service(root, "db", "sleep 30", extra = "depends:\n  - \"network\"\n")
    service(root, "unrelated", "sleep 30")
    target(root, "app", @["db"])
    let bridge = newBridge(root)
    defer: bridge.cleanup(root)
    check bridge.status("db")["enablement"].getStr == "static"
    check bridge.status("network")["enablement"].getStr == "disabled"
    discard bridge.dispatch("target.start", "app")
    check bridge.startHistory == @["network", "db"]
    check bridge.status("network")["state"].getStr == "active"
    check bridge.status("unrelated")["state"].getStr == "inactive"
    # Starting a single non-target unit does not pull in its dependencies.
    discard bridge.deactivate()
    discard bridge.dispatch("service.start", "db")
    check bridge.status("network")["state"].getStr == "inactive"

  test "multi-unit decfiles behave as targets":
    let root = tempRoot("multi")
    unitFile(root, "stack", "description: \"s\"\ntype: \"multi\"\n" &
      "service api {\n  exec \"sleep 30\"\n}\nservice worker {\n  exec \"sleep 30\"\n}\n")
    let bridge = newBridge(root)
    defer: bridge.cleanup(root)
    check bridge.dispatch("target.start", "stack") == %*{"state": "active"}
    check bridge.status("stack::api")["state"].getStr == "active"
    check bridge.status("stack::worker")["state"].getStr == "active"
    check bridge.status("stack")["members"] == %*["stack::api", "stack::worker"]
    check bridge.dispatch("target.stop", "stack") == %*{"state": "inactive"}
    check bridge.status("stack::api")["state"].getStr == "inactive"
    check bridge.status("stack::worker")["state"].getStr == "inactive"

  test "unit.activate starts the boot target from default-target":
    let root = tempRoot("boot")
    service(root, "network", "sleep 30")
    service(root, "sshd", "sleep 30", extra = "depends:\n  - \"network\"\n")
    service(root, "enabled-only", "sleep 30")
    target(root, "multi-user", @["sshd"])
    createDir(root / "etc/enabled")
    createSymlink(root / "etc/enabled-only.kg", root / "etc/enabled/enabled-only.kg")
    writeFile(root / "etc/default-target", "multi-user\n")
    let bridge = newBridge(root)
    defer: bridge.cleanup(root)
    check bridge.dispatch("target.get-default", "") == %*{"name": "multi-user"}
    let result = bridge.dispatch("unit.activate", "")
    check result == %*{"started": 2, "failed": []}
    check bridge.status("network")["state"].getStr == "active"
    check bridge.status("sshd")["state"].getStr == "active"
    check bridge.status("enabled-only")["state"].getStr == "inactive"
    check bridge.status("multi-user")["state"].getStr == "active"

  test "without default-target the boot target is default (enabled/ links)":
    let root = tempRoot("bootdefault")
    service(root, "a", "sleep 30")
    service(root, "b", "sleep 30")
    service(root, "missing-dep", "sleep 30", extra = "depends:\n  - \"absent\"\n")
    let bridge = newBridge(root)
    defer: bridge.cleanup(root)
    for name in ["a", "missing-dep"]:
      discard bridge.dispatch("service.enable", name)
    check bridge.dispatch("target.get-default", "") == %*{"name": "default"}
    let result = bridge.dispatch("unit.activate", "")
    check result["started"].getInt == 1
    check result["failed"].len == 1
    check result["failed"][0]["name"].getStr == "missing-dep"
    check bridge.status("a")["state"].getStr == "active"
    check bridge.status("b")["state"].getStr == "inactive"

  test "deactivate stops individually started units in reverse order":
    let root = tempRoot("deactivate")
    service(root, "a", "sleep 30")
    service(root, "b", "sleep 30")
    target(root, "t", @["a"])
    let bridge = newBridge(root)
    defer: bridge.cleanup(root)
    discard bridge.dispatch("target.start", "t")
    discard bridge.dispatch("service.start", "b")
    let result = bridge.dispatch("unit.deactivate", "")
    check result == %*{"stopped": 2, "failed": []}
    check bridge.activeUnits().len == 0
    check bridge.status("t")["state"].getStr == "inactive"

  test "isolate stops exactly the units the target does not require":
    let root = tempRoot("isolate")
    service(root, "network", "sleep 30")
    service(root, "web", "sleep 30", extra = "depends:\n  - \"network\"\n")
    service(root, "stray", "sleep 30")
    service(root, "other", "sleep 30")
    target(root, "prod", @["web"])
    let bridge = newBridge(root)
    defer: bridge.cleanup(root)
    discard bridge.dispatch("service.start", "stray")
    discard bridge.dispatch("service.start", "other")
    check bridge.dispatch("target.isolate", "prod") == %*{"state": "active"}
    check bridge.activeUnits() == @["network", "web"]

  test "set-default validates and get-default reads it":
    let root = tempRoot("setdefault")
    target(root, "rescue", @[])
    service(root, "web", "sleep 30")
    let bridge = newBridge(root)
    defer: bridge.cleanup(root)
    check bridge.dispatch("target.set-default", "rescue") == newJObject()
    check readFile(root / "etc/default-target") == "rescue\n"
    check bridge.dispatch("target.get-default", "") == %*{"name": "rescue"}
    check codeOf(proc() = discard bridge.dispatch("target.set-default", "web")) == "E_UNSUPPORTED"

suite "native enablement":
  test "enable and disable honour --target and --now":
    let root = tempRoot("enable")
    service(root, "web", "sleep 30")
    target(root, "prod", @[])
    let bridge = newBridge(root)
    defer: bridge.cleanup(root)
    check bridge.dispatch("service.enable", "web", %*{"now": true}) == newJObject()
    check symlinkExists(root / "etc/enabled/web.kg")
    check bridge.status("web")["state"].getStr == "active"
    check bridge.status("web")["enablement"].getStr == "enabled"
    discard bridge.dispatch("service.disable", "web", %*{"now": true})
    check not symlinkExists(root / "etc/enabled/web.kg")
    check bridge.status("web")["state"].getStr == "inactive"
    discard bridge.dispatch("service.enable", "web", %*{"target": "prod"})
    check symlinkExists(root / "etc/targets/prod/web.kg")
    check bridge.status("prod")["members"] == %*["web"]
    discard bridge.dispatch("service.disable", "web", %*{"target": "prod"})
    check not symlinkExists(root / "etc/targets/prod/web.kg")
    check codeOf(proc() = discard bridge.dispatch("service.enable", "web",
      %*{"target": "nowhere"})) == "E_NOT_FOUND"
    check codeOf(proc() = discard bridge.dispatch("service.enable", "web",
      %*{"now": "maybe"})) == "E_USAGE"

  test "sub-units cannot be enabled or disabled":
    let root = tempRoot("subenable")
    unitFile(root, "stack", "description: \"s\"\ntype: \"multi\"\nservice api {\n  exec \"sleep 30\"\n}\n")
    let bridge = newBridge(root)
    defer: bridge.cleanup(root)
    check codeOf(proc() = discard bridge.dispatch("service.enable", "stack::api")) == "E_UNSUPPORTED"
    check codeOf(proc() = discard bridge.dispatch("service.disable", "stack::api")) == "E_UNSUPPORTED"
    check not dirExists(root / "etc/enabled") or
      toSeq(walkDir(root / "etc/enabled")).len == 0

  test "unit.list reports every unit with its enablement":
    let root = tempRoot("list")
    service(root, "web", "sleep 30")
    unitFile(root, "stack", "description: \"s\"\ntype: \"multi\"\nservice api {\n  exec \"sleep 30\"\n}\n")
    target(root, "prod", @["web"])
    let bridge = newBridge(root)
    defer: bridge.cleanup(root)
    check bridge.dispatch("unit.list", "") == %*{"units": [
      {"name": "default", "subsystem": "target", "enablement": "static"},
      {"name": "prod", "subsystem": "target", "enablement": "disabled"},
      {"name": "stack", "subsystem": "target", "enablement": "disabled"},
      {"name": "stack::api", "subsystem": "service", "enablement": "static"},
      {"name": "web", "subsystem": "service", "enablement": "static"}]}
    check bridge.dispatch("unit.list", "", %*{"subsystem": "service"})["units"].len == 2

suite "native load and validation":
  test "a reserved default.kg does not hide other errors":
    let root = tempRoot("defaultkg")
    unitFile(root, "default", "description: \"old\"\ntype: \"simple\"\nservice {\n  exec \"sleep 30\"\n}\n")
    service(root, "web", "sleep 30")
    target(root, "broken", @["absent"])
    target(root, "a", @["b"])
    target(root, "b", @["a"])
    unitFile(root, "typo", "description: \"t\"\ntype: \"simpel\"\nservice {\n  exec \"true\"\n}\n")
    let bridge = newBridge(root)
    defer: bridge.cleanup(root)
    let loaded = bridge.dispatch("unit.load", "")
    let messages = loaded["errors"].mapIt(it["message"].getStr).join("\n")
    check "reserved" in messages
    check "broken wants unknown unit absent" in messages
    check "native target cycle" in messages
    check "unknown type 'simpel'" in messages
    check loaded["loaded"].getInt == 5
    check bridge.dispatch("unit.validate", "web") == %*{"valid": true, "diagnostics": []}
    check not bridge.dispatch("unit.validate", "default")["valid"].getBool
    check not bridge.dispatch("unit.validate", "broken")["valid"].getBool
    check not bridge.dispatch("unit.validate", "a")["valid"].getBool
    # default.kg never starts; default is the built-in target.
    check bridge.resolve("default").subsystem == "target"
    check codeOf(proc() = discard bridge.dispatch("target.start", "a")) == "E_UNIT_STATE"

  test "target decfiles with function blocks are invalid":
    let root = tempRoot("targetfn")
    unitFile(root, "t", "description: \"t\"\ntype: \"target\"\nservice {\n  exec \"true\"\n}\n")
    let bridge = newBridge(root)
    defer: bridge.cleanup(root)
    let result = bridge.dispatch("unit.validate", "t")
    check not result["valid"].getBool
    check "no function block" in $result

suite "native status text":
  test "mapping follows Appendix A":
    check mapNativeStatus("running", true, false).state == "active"
    check mapNativeStatus("mounted", true, false).state == "active"
    check mapNativeStatus("stopped", true, false).state == "inactive"
    check mapNativeStatus("", false, false).state == "inactive"
    let requested = mapNativeStatus("stopped with an exit code 143", true, true)
    check requested.state == "inactive" and requested.exitCode == 143
    let failure = mapNativeStatus("stopped with an exit code 143", true, false)
    check failure.state == "failed" and failure.hasExitCode
    check mapNativeStatus("weird", true, false).state == "unknown"
    check nativeStatusText(%*{"state": "unknown", "detail": "weird"}) == "weird"
    for (state, text) in [("active", "running"), ("inactive", "stopped"),
                          ("activating", "starting"), ("failed", "failed")]:
      check nativeStatusText(%*{"state": state, "members": []}) == text

suite "native per-unit cgroups":
  proc fakeCgroupfs(): CgroupSystem =
    ## A directory tree standing in for cgroupfs: cgroup.kill SIGKILLs the
    ## pids in cgroup.procs, and cgroup.events reports them.
    result = defaultCgroupSystem()
    result.makeDir = proc(path: string) =
      createDir(path)
      writeFile(path / "cgroup.procs", "")
    result.writeFile = proc(path, value: string) =
      if extractFilename(path) == "cgroup.kill":
        for line in readFile(parentDir(path) / "cgroup.procs").splitLines:
          if line.strip.len > 0: discard kill(Pid(parseInt(line.strip)), SIGKILL)
      else: writeFile(path, value)
    result.readFile = proc(path: string): string =
      if extractFilename(path) == "cgroup.events":
        var alive = false
        for line in readFile(parentDir(path) / "cgroup.procs").splitLines:
          if line.strip.len > 0 and kill(Pid(parseInt(line.strip)), 0) == 0:
            alive = true
        "populated " & (if alive: "1" else: "0") & "\n"
      else: readFile(path)
    result.removeDir = proc(path: string) = os.removeDir(path)
    result.listDirs = proc(path: string): seq[string] =
      for kind, child in walkDir(path):
        if kind == pcDir: result.add extractFilename(child)

  test "native units run in units/UNIT.unit and stop kills that cgroup":
    let root = tempRoot("cgroup")
    service(root, "web", "sleep 30")
    let layout = coreCgroups(root / "cgroup/jumpstart/cores", "serviceHandler")
    createDir(layout.units)
    let ctx = newNativeContext(root / "etc", root / "run", newReaper(),
      stopTimeoutMs = 3000, cgroups = some(layout), cgroupSystem = fakeCgroupfs())
    let bridge = newNativeBridge(ctx, resetRuntime = true)
    defer: bridge.cleanup(root)
    discard bridge.dispatch("service.start", "web")
    let unitDir = layout.units / "web.unit"
    check dirExists(unitDir)
    let pid = bridge.status("web")["main_pid"].getInt
    check readFile(unitDir / "cgroup.procs").strip == $pid
    check bridge.status("web")["pids"] == %*[pid]
    # kill signals every process listed in the unit cgroup.
    discard bridge.dispatch("service.kill", "web", %*{"signal": "CONT"})
    discard bridge.dispatch("service.stop", "web")
    check not dirExists(unitDir)
    check kill(Pid(pid), 0) != 0
