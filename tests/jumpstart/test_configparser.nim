import std/[algorithm, os, strutils, unittest]
import ../../jumpstart/configParser

suite "Jumpstart service configuration":
  test "terminal service setting is explicit and defaults to false":
    let dir = getTempDir() / "jumpstart-configparser-test"
    removeDir(dir)
    createDir(dir)
    defer: removeDir(dir)

    writeFile(dir / "getty.kg", """
description: "getty"
type: "simple"
service {
  terminal true
  exec "/sbin/agetty tty1 linux"
}
""")
    let interactive = parseUnit(dir, "getty")
    check interactive.services.len == 1
    check interactive.services[0].terminal

    writeFile(dir / "daemon.kg", """
description: "daemon"
type: "simple"
service {
  exec "/bin/example"
}
""")
    let daemon = parseUnit(dir, "daemon")
    check daemon.services.len == 1
    check not daemon.services[0].terminal

  test "target type and wants are recognized":
    let dir = getTempDir() / "jumpstart-target-parser-test"
    removeDir(dir)
    createDir(dir)
    defer: removeDir(dir)
    writeFile(dir / "multi-user.kg", """
description: "multi user"
type: "target"
wants:
  - "network"
  - "sshd"
""")
    let target = parseUnit(dir, "multi-user")
    check target.unitType == utTarget
    check target.wants == @["network", "sshd"]
    check getUnitKindFromConfig(target) == "target"

  test "quoted command arguments are literal values":
    check literalArg("\"tmpfs\"") == "tmpfs"
    check literalArg("\"a \\\"b\\\" \\\\ c\"") == "a \"b\" \\ c"
    check literalArg("755") == "755"
    check literalArg("true") == "true"
    check literalArg("\"a\" \"b\"") == "\"a\" \"b\""
    let dir = getTempDir() / "jumpstart-literal-parser-test"
    removeDir(dir)
    createDir(dir)
    defer: removeDir(dir)
    writeFile(dir / "stack.kg", """
description: "stack"
type: "multi"
mount data {
  from "tmpfs"
  to "/mnt/data"
  fstype "tmpfs"
  extra_args "size=512M"
}
service main {
  exec_pre "/bin/prepare --fast"
  exec "/usr/bin/daemon"
  exec_post "/bin/cleanup"
}
timer sweep {
  interval 60
  service "sweeper"
  on_missed "run"
}
""")
    let config = parseUnit(dir, "stack")
    check config.mounts[0].fromPath == "tmpfs"
    check config.mounts[0].toPath == "/mnt/data"
    check config.mounts[0].fstype == "tmpfs"
    check config.mounts[0].extraArgs == "size=512M"
    check config.services[0].execPre == "/bin/prepare --fast"
    check config.services[0].exec == "/usr/bin/daemon"
    check config.services[0].execPost == "/bin/cleanup"
    check config.timers[0].service == "sweeper"
    check config.timers[0].onMissed == omRun
    check config.functionBlocks == @["mount data", "service main", "timer sweep"]
    check unitDiagnostics(config).len == 0

  test "validation reports what parsing tolerates":
    let dir = getTempDir() / "jumpstart-diagnostics-parser-test"
    removeDir(dir)
    createDir(dir)
    defer: removeDir(dir)
    writeFile(dir / "typo.kg", "type: \"simpel\"\nservice {\n  exec \"true\"\n}\n")
    let typo = unitDiagnostics(parseUnit(dir, "typo"))
    check typo.len == 2
    check "description" in typo[0]
    check "simpel" in typo[1]
    writeFile(dir / "t.kg", "description: \"t\"\ntype: \"target\"\nservice {\n  exec \"true\"\n}\n")
    check "no function block" in unitDiagnostics(parseUnit(dir, "t"))[0]
    writeFile(dir / "m.kg", "description: \"m\"\ntype: \"mount\"\nmount {\n  from \"x\"\n}\n")
    check "missing from, to, or fstype" in unitDiagnostics(parseUnit(dir, "m"))[0]
    writeFile(dir / "e.kg", "description: \"e\"\ntype: \"simple\"\n")
    check "exactly one service block" in unitDiagnostics(parseUnit(dir, "e"))[0]

  test "unit listing includes symlinked decfiles":
    let dir = getTempDir() / "jumpstart-listing-parser-test"
    removeDir(dir)
    createDir(dir / "store")
    defer: removeDir(dir)
    writeFile(dir / "store/real.kg", "description: \"r\"\ntype: \"target\"\n")
    writeFile(dir / "plain.kg", "description: \"p\"\ntype: \"target\"\n")
    createSymlink(dir / "store/real.kg", dir / "linked.kg")
    var names = getAllUnitsInDir(dir)
    names.sort()
    check names == @["linked", "plain"]
