import std/[os, unittest]
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
