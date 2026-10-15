import std/unittest
import ../../jumpstart/[configParser, types, unitdispatch]

suite "Jumpstart unit dispatch":
  test "simple unit kinds come from parsed configuration":
    check requestedUnitKind(UnitConfig(unitType: utSimple), "web") == ukService
    check requestedUnitKind(UnitConfig(unitType: utMount), "data") == ukMount
    check requestedUnitKind(UnitConfig(unitType: utTimer), "cleanup") == ukTimer

  test "qualified multi-units use their sub-unit definition":
    let config = UnitConfig(
      unitType: utMulti,
      services: @[ServiceConfig(name: "worker")],
      mounts: @[MountConfig(name: "data")],
      timers: @[TimerConfig(name: "cleanup")]
    )
    check requestedUnitKind(config, "stack::worker") == ukService
    check requestedUnitKind(config, "stack::data") == ukMount
    check requestedUnitKind(config, "stack::cleanup") == ukTimer

  test "unqualified and unknown multi-units are rejected":
    let config = UnitConfig(unitType: utMulti)
    expect ValueError:
      discard requestedUnitKind(config, "stack")
    expect ValueError:
      discard requestedUnitKind(config, "stack::missing")
