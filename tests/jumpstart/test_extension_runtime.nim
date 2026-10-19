import std/[tables, unittest]
import ../../jumpstart/cores/lifecycle/dispatch,
  ../../jumpstart/cores/backends/extension_runtime,
  ../../jumpstart/cores/manifest/[manifest, modes, types]
import jumpstartcore/registry

proc manifestDefinition(): CoreManifest =
  result.manifestVersion = 1
  result.name = "demo"
  result.modes = {cmSystem}
  result.subsystems = @["core"]
  result.activation = asNone
  result.operations = @[OperationEntry(name: "core.verify", backend: manifest.bkExec,
    common: CommonOptions(timeoutMs: 1000, hasSandbox: true, sandbox: true,
      workingDirectory: "/"), executable: "bin/adapter")]

suite "extension runtime bridge":
  test "validated manifest becomes daemon definition":
    let d = definitionFor(manifestDefinition(), cmSystem)
    check d.runtime.name == "demo"
    check d.runtime.state == csUnloaded
    check d.plan.operations.hasKey("core.verify")
    check d.plan.operations["core.verify"].backend.kind == dispatch.bkExec

  test "delegations populate lifecycle dependencies":
    var m = manifestDefinition()
    m.operations[0].backend = manifest.bkDelegate
    m.operations[0].delegateCore = "other"
    m.operations[0].delegateOperation = "core.verify"
    m.operations[0].common = CommonOptions()
    let d = definitionFor(m, cmSystem)
    check d.runtime.delegatesTo == @["other"]

  test "the built-in serviceHandler plan covers Appendix A":
    let plan = nativePlan("jumpstart v2.0.0", cmSystem)
    check plan.operations.hasKey("service.start")
    check plan.operations["service.start"].backend.kind == dispatch.bkNative
    check plan.operations.hasKey("unit.resolve")

  test "only cores claiming unit take part in resolution":
    var m = manifestDefinition()
    check not m.claimsUnit
    m.subsystems.add "unit"
    check m.claimsUnit
    check CurrentManifestVersion == 1
