import std/[os, sequtils, sets, strutils, tables, times, unittest]
import ../../../../jumpstart/cores/native/native_targets

proc tempRoot(label: string): string =
  result = getTempDir() / ("jumpstart-native-targets-" & label & "-" &
    $getCurrentProcessId() & "-" & $epochTime())
  createDir(result)

proc touchUnit(root, name: string) = writeFile(root / (name & ".kg"), "fixture\n")

proc unit(name: string, kind = nukService, wants: seq[string] = @[],
          members: seq[string] = @[], depends: seq[string] = @[],
          after: seq[string] = @[]): NativeUnit =
  NativeUnit(name: name, kind: kind, wants: wants, members: members,
    depends: depends, after: after)

proc errorCode(body: proc()) : string =
  try: body()
  except NativeTargetError as e: return e.code

suite "serviceHandler native target model":
  test "built-in default exists and reads enabled links deterministically":
    let root = tempRoot("default"); defer: removeDir(root)
    for name in ["zeta", "alpha"]: touchUnit(root, name)
    var model = initNativeTargetModel(root,
      [unit("zeta"), unit("alpha")])
    check model.isTarget("default")
    check model.subsystem("default") == "target"
    check model.directMembers("default").len == 0
    model.enable("zeta")
    model.enable("alpha")
    check model.directMembers("default") == @["alpha", "zeta"]
    check symlinkExists(root / "enabled/alpha.kg")
    model.disable("alpha")
    check model.directMembers("default") == @["zeta"]

  test "wants, target links and nested membership are transitive":
    let root = tempRoot("members"); defer: removeDir(root)
    for name in ["web", "db", "cache", "base", "prod"]: touchUnit(root, name)
    var model = initNativeTargetModel(root, [
      unit("web"), unit("db"), unit("cache"),
      unit("base", nukTarget, wants = @["db"]),
      unit("prod", nukTarget, wants = @["base", "web"])])
    model.enable("cache", "prod")
    check model.directMembers("prod") == @["base", "web", "cache"]
    check model.transitiveMembers("prod") == @["db", "web", "cache"]
    check model.enablement("db") == neStatic
    check model.enablement("cache") == neEnabled
    check model.enablement("web") == neStatic

  test "enablement searches every target and disable is idempotent":
    let root = tempRoot("enablement"); defer: removeDir(root)
    for name in ["thing", "other", "boot"]: touchUnit(root, name)
    var model = initNativeTargetModel(root,
      [unit("thing"), unit("other"), unit("boot", nukTarget)])
    check model.enablement("thing") == neDisabled
    model.enable("thing", "boot")
    check model.enablement("thing") == neEnabled
    model.enable("thing", "boot")
    model.disable("thing", "boot")
    model.disable("thing", "boot")
    check model.enablement("thing") == neDisabled

  test "sub-units cannot be linked but can be fixed wants":
    let root = tempRoot("subunits"); defer: removeDir(root)
    for name in ["stack", "selected"]: touchUnit(root, name)
    var model = initNativeTargetModel(root, [
      unit("stack", nukMulti, members = @["stack::api", "stack::worker"]),
      unit("selected", nukTarget, wants = @["stack::worker"])])
    check model.hasUnit("stack::worker")
    check not model.hasUnit("stack::missing")
    check model.transitiveMembers("selected") == @["stack::worker"]
    check model.enablement("stack::worker") == neStatic
    check errorCode(proc() = model.enable("stack::worker", "selected")) == "E_UNSUPPORTED"
    check errorCode(proc() = model.disable("stack::worker", "selected")) == "E_UNSUPPORTED"

  test "multi definitions map to target and expand all sub-units":
    let root = tempRoot("multi"); defer: removeDir(root)
    touchUnit(root, "stack")
    let model = initNativeTargetModel(root, [
      unit("stack", nukMulti, members = @["stack::api", "stack::worker"])])
    check model.subsystem("stack") == "target"
    check model.subsystem("stack::api") == "service"
    check model.subsystem("stack::nope") == ""
    check model.directMembers("stack") == @["stack::api", "stack::worker"]

  test "cycles through wants and links are detected and links roll back":
    let root = tempRoot("cycles"); defer: removeDir(root)
    for name in ["a", "b"]: touchUnit(root, name)
    let cyclic = initNativeTargetModel(root, [
      unit("a", nukTarget, wants = @["b"]),
      unit("b", nukTarget, wants = @["a"])])
    check cyclic.targetCycle() == @["a", "b", "a"]
    check errorCode(proc() = cyclic.validateTargets()) == "E_UNIT_STATE"

    removeDir(root); createDir(root)
    for name in ["a", "b"]: touchUnit(root, name)
    var linked = initNativeTargetModel(root,
      [unit("a", nukTarget), unit("b", nukTarget)])
    linked.enable("b", "a")
    check errorCode(proc() = linked.enable("a", "b")) == "E_UNIT_STATE"
    check not symlinkExists(root / "targets/b/a.kg")
    check linked.targetCycle().len == 0

  test "reserved default decfile and missing members fail validation":
    let root = tempRoot("validation"); defer: removeDir(root)
    writeFile(root / "default.kg", "invalid")
    let empty = initNativeTargetModel(root)
    check errorCode(proc() = empty.validateTargets()) == "E_UNIT_STATE"
    removeFile(root / "default.kg")
    let missing = initNativeTargetModel(root,
      [unit("broken", nukTarget, wants = @["absent"])])
    check errorCode(proc() = missing.validateTargets()) == "E_UNIT_NOT_FOUND"
    check errorCode(proc() = discard initNativeTargetModel(root,
      [unit("default", nukTarget)])) == "E_UNIT_STATE"

  test "default target storage defaults, persists atomically and validates":
    let root = tempRoot("storage"); defer: removeDir(root)
    touchUnit(root, "rescue")
    let model = initNativeTargetModel(root, [unit("rescue", nukTarget)])
    check model.getDefaultTarget() == "default"
    model.setDefaultTarget("rescue")
    check readFile(root / "default-target") == "rescue\n"
    check model.getDefaultTarget() == "rescue"
    check toSeq(walkFiles(root / "default-target.tmp-*")).len == 0
    writeFile(root / "default-target", "rescue")
    check errorCode(proc() = discard model.getDefaultTarget()) == "E_UNIT_STATE"
    writeFile(root / "default-target", "missing\n")
    check errorCode(proc() = discard model.getDefaultTarget()) == "E_UNIT_NOT_FOUND"

  test "activation includes static members and dependency closure in order":
    let root = tempRoot("activation"); defer: removeDir(root)
    for name in ["network", "db", "web", "late", "prod"]: touchUnit(root, name)
    let model = initNativeTargetModel(root, [
      unit("network"),
      unit("db", depends = @["network"]),
      unit("web", depends = @["db"]),
      unit("late", after = @["web"]),
      unit("prod", nukTarget, wants = @["web", "late"])])
    check model.activationPlan("prod") == @["network", "db", "web", "late"]

  test "activation rejects dependency ordering cycles":
    let root = tempRoot("depcycle"); defer: removeDir(root)
    for name in ["a", "b", "boot"]: touchUnit(root, name)
    let model = initNativeTargetModel(root, [
      unit("a", depends = @["b"]), unit("b", after = @["a"]),
      unit("boot", nukTarget, wants = @["a"])])
    check errorCode(proc() = discard model.activationPlan("boot")) == "E_UNIT_STATE"

  test "isolation starts target and stops outsiders in reverse history":
    let root = tempRoot("isolate"); defer: removeDir(root)
    for name in ["network", "web", "old", "stray", "prod"]: touchUnit(root, name)
    let model = initNativeTargetModel(root, [
      unit("network"), unit("web", depends = @["network"]), unit("old"),
      unit("stray"), unit("prod", nukTarget, wants = @["web"])])
    let plan = model.isolationPlan("prod",
      @["old", "network", "web", "stray"],
      @["network", "old", "stray", "web"])
    check plan.start == @["network", "web"]
    check plan.keep == @["network", "web"]
    check plan.stop == @["stray", "old"]
    check deactivationPlan(@["network", "web", "web", "old"],
      @["network", "web", "old"]) == @["old", "web", "network"]
    # Only active units are planned: a history with nothing active is empty,
    # and units that stopped on their own are skipped.
    check deactivationPlan(@["network", "web"], newSeq[string]()).len == 0
    check deactivationPlan(@["network", "web", "old"], @["network", "old"]) ==
      @["old", "network"]

  test "a reserved default.kg is reported together with every other error":
    let root = tempRoot("allerrors")
    writeFile(root / "default.kg", "invalid")
    for name in ["a", "b", "broken"]: touchUnit(root, name)
    let model = initNativeTargetModel(root, [
      unit("a", nukTarget, wants = @["b"]),
      unit("b", nukTarget, wants = @["a"]),
      unit("broken", nukTarget, wants = @["absent"])])
    let errors = model.validationErrors()
    check errors.len == 3
    check errors[0].name == "default.kg"
    check errors.anyIt(it.code == "E_UNIT_NOT_FOUND" and it.name == "broken")
    check errors.anyIt("cycle" in it.message)
    try:
      model.validateTargets()
      check false
    except NativeTargetError as e:
      check "absent" in e.msg and "cycle" in e.msg and "reserved" in e.msg
    # Unrelated targets are still valid on their own.
    check model.targetDiagnostics("a").len == 0

  test "sub-unit kinds, per sub-unit dependencies and multi start order":
    let root = tempRoot("subkinds")
    touchUnit(root, "stack"); touchUnit(root, "db")
    var stack = unit("stack", nukMulti,
      members = @["stack::data", "stack::api", "stack::sweep"])
    stack.memberKinds = @[nukMount, nukService, nukTimer]
    stack.subDepends["api"] = @["db"]
    let model = initNativeTargetModel(root, [stack, unit("db")])
    check model.subsystem("stack::data") == "mount"
    check model.subsystem("stack::api") == "service"
    check model.subsystem("stack::sweep") == "timer"
    check model.hardDependencies("stack::api") == @["db"]
    # Mounts, then services, then timers; db before the service needing it.
    check model.activationPlan("stack") == @["db", "stack::data", "stack::api", "stack::sweep"]

  test "activation reports units with unknown dependencies and starts the rest":
    let root = tempRoot("report")
    for name in ["ok", "bad", "boot"]: touchUnit(root, name)
    let model = initNativeTargetModel(root, [
      unit("ok"), unit("bad", depends = @["absent"]),
      unit("boot", nukTarget, wants = @["ok", "bad"])])
    let report = model.activationReport("boot")
    check report.plan == @["ok"]
    check report.failed.len == 1
    check report.failed[0].name == "bad"
    check "absent" in report.failed[0].message
    check errorCode(proc() = discard model.activationPlan("boot")) == "E_UNIT_NOT_FOUND"

  test "deactivation plans include active units that were started individually":
    let root = tempRoot("deactivate")
    for name in ["a", "b", "t"]: touchUnit(root, name)
    let model = initNativeTargetModel(root, [unit("a"), unit("b"),
      unit("t", nukTarget, wants = @["a", "b"])])
    check deactivationPlan(@["a"], active = @["a", "b"]) == @["a", "b"]
    check model.deactivationPlanForTarget("t", @["a"], active = @["b"]) == @["a", "b"]
    check model.requiredUnits("t") == ["a", "b"].toHashSet
