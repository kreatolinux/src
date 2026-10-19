import std/[strutils, unittest]
import jumpstartcore/names

suite "core and unit names":
  test "extension core names obey grammar and reserved set":
    for name in ["systemd", "OpenRC", "core_1", "a-b"]: check validCoreName(name)
    for name in ["", "1core", "bad.name", "bad/name", "ümlaut"]: check not validCoreName(name)
    check validCoreName("a".repeat(64))
    check not validCoreName("a".repeat(65))
    for name in ReservedCoreNames: check not validCoreName(name)
    check validCoreName("serviceHandler", extension = false)

  test "unit names are opaque constrained UTF-8":
    for name in ["sshd.service", "getty@tty1.service", "stack::worker", "日本語",
                 "-.mount", "-.slice", "-", "-option", "--x", "a-b.service"]:
      check validUnitName(name)
    for name in ["", "a/b", "-/x", "-a b", "has space", "has\ttab", "line\nfeed",
                 "no\u00a0break", "ideographic\u3000space"]:
      check not validUnitName(name)
    check validUnitName("a".repeat(255))
    check not validUnitName("a".repeat(256))
    check not validUnitName("\xFF")
    check validUnitName("é".repeat(127) & "a") # 255 UTF-8 bytes
    check not validUnitName("é".repeat(128))    # 256 UTF-8 bytes
    check validUnitName("e\u0301") # opaque: no Unicode normalization

  test "operation grammar and reserved subsystems":
    for name in ["service.start", "target.set-default", "a1.b-2"]:
      check validOperationName(name)
    for name in ["Service.start", "service.Start", "service", ".start", "service.", "a.b.c", "a_b.c"]:
      check not validOperationName(name)
    check operationSubsystem("target.set-default") == "target"
    check operationSubsystem("invalid") == ""
    check isReservedSubsystem("network")
    check not isReservedSubsystem("service")

  test "qualified and unqualified references preserve unit bytes":
    let plain = parseUnitRef("getty@tty1.service")
    check not plain.qualified
    check plain.unit == "getty@tty1.service"
    let qualified = parseUnitRef("systemd/getty@tty1.service")
    check qualified.qualified
    check qualified.core == "systemd"
    check qualified.unit == "getty@tty1.service"
    let unicode = parseUnitRef("core/日本語@.service")
    check unicode.unit == "日本語@.service"
    expect ValueError: discard parseUnitRef("bad/core/name")
    let dash = parseUnitRef("-.mount")
    check not dash.qualified and dash.unit == "-.mount"
    let dashQualified = parseUnitRef("systemd/-.mount")
    check dashQualified.qualified and dashQualified.core == "systemd" and
      dashQualified.unit == "-.mount"
    expect ValueError: discard parseUnitRef("systemd/-bad name")
    expect ValueError: discard parseUnitRef("systemd/")
    expect ValueError: discard parseUnitRef("/unit")
