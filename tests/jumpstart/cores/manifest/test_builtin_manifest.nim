import std/[sets, strutils, unittest]
import ../../../../jumpstart/cores/manifest/[builtin_manifest, manifest, modes, types]
import jumpstartcore/registry

suite "serviceHandler built-in manifest (Appendix A)":
  test "metadata tracks the running Jumpstart version":
    let m = serviceHandlerManifest("jumpstart v1.2.0")
    check m.manifestVersion == 1
    check m.name == "serviceHandler"
    check m.description == "Jumpstart native service handler"
    check m.coreVersion == "1.2.0"
    check m.version == "1.2.0"
    check m.jumpstart == "=1.2.0"
    check m.jumpstartRange.contains(parseVersion("1.2.0"))
    check not m.jumpstartRange.contains(parseVersion("1.2.1"))
    check m.modes == {cmSystem, cmUser}
    check m.account == "root"
    check m.activation == asCore
    check not m.hasSupervisor
    check m.subsystems == @["unit", "service", "mount", "timer", "target"]
    check serviceHandlerManifest("1.3.0").coreVersion == "1.3.0"
    expect ValueError: discard serviceHandlerManifest("native")

  test "operations are exactly the Appendix A table":
    let m = serviceHandlerManifest("1.2.0")
    check m.operations.len == 33
    var names = initHashSet[string]()
    for op in m.operations:
      names.incl op.name
      if op.name in ["unit.translate", "service.reload"]:
        check op.backend == bkUnsupported
      else:
        check op.backend == bkNative
    # Completeness: every verb of every claimed subsystem, nothing else.
    var expected = initHashSet[string]()
    for sub in m.subsystems:
      for spec in operationsForSubsystem(1, sub): expected.incl spec.name
    check names == expected
    for absent in ["core.verify", "log.read", "socket.start", "swap.start", "path.start"]:
      check absent notin names
      check not isServiceHandlerNative(absent)
    check isServiceHandlerNative("service.kill")
    check not isServiceHandlerNative("service.reload")

  test "resolved operations are in registry order with no options":
    let ops = serviceHandlerOps("1.2.0", cmSystem)
    check ops.len == 33
    var last = -1
    let reg = registry(1)
    for op in ops:
      var index = -1
      for i, spec in reg:
        if spec.name == op.name: index = i
      check index > last
      last = index
      check op.timeoutMs == 0
      check op.executable.len == 0
    check serviceHandlerOps("1.2.0", cmUser).len == 33

  test "show prints the virtual manifest":
    let lines = formatShow(serviceHandlerManifest("1.2.0"), cmSystem, "yes", resolved = false)
    check lines[0 .. 8] == @[
      "name: serviceHandler",
      "core_version: 1.2.0",
      "version: 1.2.0",
      "jumpstart: =1.2.0",
      "modes: system user",
      "account: root",
      "activation: core",
      "enabled: yes",
      "subsystems: unit service mount timer target"]
    check lines[9] == "operations:"
    check lines[10] == "  unit.list        native"
    check "  unit.translate   unsupported" in lines
    check "  target.set-default native" in lines
    check lines.len == 10 + 33

  test "Appendix A text rendering":
    let text = appendixAText("1.2.0")
    check text.startsWith("manifest_version: 1\nname: \"serviceHandler\"\n")
    check "core_version: \"1.2.0\"\nversion: \"1.2.0\"\njumpstart: \"=1.2.0\"\n" in text
    check "activation: \"core\"\n" in text
    check "  - name: \"service.reload\"\n    backend: \"unsupported\"\n" in text
    check "  - name: \"target.get-default\"\n    backend: \"native\"\n" in text
