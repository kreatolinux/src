import std/[options, sets, strutils, unittest]
import jumpstartcore/[names, protocol, registry, registry_types]

suite "versioned core operation registry":
  test "version 1 has the complete ordered vocabulary without duplicates":
    check RegistryV1.len == 54
    var names = initHashSet[string]()
    for op in RegistryV1:
      check op.name notin names
      names.incl op.name
    check RegistryV1[0].name == "core.verify"
    check RegistryV1[^1].name == "log.vacuum"
    check operationsForSubsystem(1, "unit").len == 7
    check operationsForSubsystem(1, "service").len == 8
    check operationsForSubsystem(1, "target").len == 8
    check operationsForSubsystem(1, "network").len == 0

  test "registry is selected strictly by manifest version":
    check registry(CurrentManifestVersion) == RegistryV1
    expect ValueError: discard registry(0)
    expect ValueError: discard registry(2)

  test "lookup does not confuse unknown verbs and subsystems":
    check findOperation(1, "service.start").isSome
    check findOperation(1, "service.bogus").isNone
    check findOperation(1, "bogus.start").isNone
    check knownSubsystem(1, "log")
    check not knownSubsystem(1, "network")
    check isReservedSubsystem("network")
    check not isReservedSubsystem("service")
    check isUnitAddressedSubsystem("path")
    check not isUnitAddressedSubsystem("unit")

  test "operation classes and serialization locks follow section 11":
    check findOperation(1, "service.status").get.operationClass == ocReadOnly
    check findOperation(1, "log.follow").get.operationClass == ocStreaming
    check findOperation(1, "service.start").get.lock == olUnit
    check findOperation(1, "unit.load").get.lock == olCore
    check findOperation(1, "target.isolate").get.lock == olCore
    check findOperation(1, "log.write").get.lock == olLog
    check findOperation(1, "unit.activate").get.lock == olNone
    check findOperation(1, "service.status").get.lock == olNone

  test "idempotency and routing metadata are exact":
    check findOperation(1, "service.start").get.idempotency == idemYes
    check findOperation(1, "service.restart").get.idempotency == idemNo
    check findOperation(1, "log.follow").get.idempotency == idemNotApplicable
    check findOperation(1, "core.verify").get.routing == orCore
    check findOperation(1, "unit.resolve").get.routing == orGlobal
    check findOperation(1, "service.start").get.routing == orUnit
    check findOperation(1, "log.read").get.routing == orUnitOrGlobal

  test "argument and result schemas include defaults and limits":
    let read = findOperation(1, "log.read").get
    check read.arguments.len == 3
    check read.arguments[2] == FieldSpec(name: "lines", kind: vkInt,
      optional: true, defaultValue: "1000", minimum: 1, maximum: 10000)
    let enable = findOperation(1, "service.enable").get
    check enable.arguments[0].name == "now"
    check not enable.arguments[0].optional
    check enable.arguments[1].name == "target"
    check enable.arguments[1].optional
    let status = findOperation(1, "service.status").get
    check status.results[^3].optional
    check status.results[^2].kind == vkIntList

  test "closed state vocabularies include every specified value":
    check ord(high(UnitState)) + 1 == 7
    check "reloading" in UnitStates
    check ord(high(EnablementState)) + 1 == 6

  test "every <subsystem>.status carries the optional since, substate and result (§12.11)":
    var count = 0
    for spec in registry(1):
      if not spec.name.endsWith(".status"): continue
      inc count
      for key in ["since", "substate", "result"]:
        let field = resultField(1, spec.name, key)
        check field.isSome
        check field.get.kind == vkString
        check field.get.optional
      # The three required fields keep their order at the front.
      check spec.results[0].name == "state"
      check spec.results[1].name == "detail"
      check spec.results[2].name == "enablement"
      check not spec.results[2].optional
    check count == 7
    # No other operation gets them.
    check resultField(1, "service.start", "since").isNone
    check resultField(1, "unit.list", "result").isNone

  test "reserved subsystems have a single source":
    check ReservedSubsystems == ReservedSubsystemNames
    for name in ReservedSubsystemNames:
      check isReservedSubsystem(name)
      check not knownSubsystem(1, name)

  test "object lists carry the item shape that §12 defines":
    let units = resultField(1, "unit.list", "units").get
    check units.itemShape == isRegistry
    check units.itemFields.len == 3
    check units.itemFields[0].name == "name"
    check resultField(1, "log.read", "entries").get.itemFields.len == 4
    check logEntryFields(1)[3].name == "message"
    for (op, field) in [("unit.load", "errors"), ("unit.validate", "diagnostics"),
                        ("unit.activate", "failed"), ("unit.deactivate", "failed")]:
      check resultField(1, op, field).get.itemShape == isCoreDefined
    check resultField(1, "socket.status", "listen").get.itemShape == isNone
    check resultField(1, "unit.list", "nope").isNone
