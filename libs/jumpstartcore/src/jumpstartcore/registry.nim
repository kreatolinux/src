## Immutable, version-keyed operation vocabulary for manifest_version 1.
import std/[options, strutils]
import ./registry_types
from ./names import isReservedSubsystem
export isReservedSubsystem

const CurrentManifestVersion* = 1

proc f(fieldName: string, kind: ValueKind, optional = false,
       defaultValue = "", minimum = 0, maximum = 0): FieldSpec =
  FieldSpec(name: fieldName, kind: kind, optional: optional, defaultValue: defaultValue,
            minimum: minimum, maximum: maximum)

proc operation(name: string, idem: Idempotency, routing: OperationRouting,
               cls: OperationClass, args: seq[FieldSpec] = @[],
               results: seq[FieldSpec] = @[]): OperationSpec =
  var lock = olNone
  if cls == ocMutating:
    if name == "unit.load" or name == "target.isolate": lock = olCore
    elif name in ["log.write", "log.rotate", "log.vacuum"]: lock = olLog
    elif name notin ["unit.activate", "unit.deactivate"]: lock = olUnit
  OperationSpec(name: name, idempotency: idem, routing: routing,
                operationClass: cls, lock: lock, arguments: args, results: results)

proc objects(fieldName: string; items: seq[FieldSpec]): FieldSpec =
  ## A list of objects whose shape §12 defines.
  FieldSpec(name: fieldName, kind: vkObjectList, itemShape: isRegistry, itemFields: items)

proc coreObjects(fieldName: string): FieldSpec =
  ## A list of objects that §12 describes only as "(list)"; the keys are the
  ## core's own (`unit.load` errors, `unit.validate` diagnostics, failures).
  FieldSpec(name: fieldName, kind: vkObjectList, itemShape: isCoreDefined)

let UnitItemV1* = @[f("name", vkString), f("subsystem", vkString), f("enablement", vkString)]
  ## §12.2: `unit.list` `units` items are `{name, subsystem, enablement}`.
let LogEntryV1* = @[f("time", vkString), f("level", vkString), f("unit", vkString),
                    f("message", vkString)]
  ## §12.10: log entries (`log.read` `entries`, `log.follow` `entry` events).

let enableArgs = @[f("now", vkBool), f("target", vkString, true)]
let stateResult = @[f("state", vkString)]
let commonStatus = @[f("state", vkString), f("detail", vkString), f("enablement", vkString),
                     f("since", vkString, true), f("substate", vkString, true),
                     f("result", vkString, true)]
  ## §12 common `<subsystem>.status` fields; `since`, `substate`, and `result`
  ## are optional everywhere (§12.11).

let RegistryV1* = @[
  operation("core.verify", idemYes, orCore, ocReadOnly, results = @[f("installed", vkBool), f("version", vkString)]),
  operation("unit.list", idemYes, orGlobal, ocReadOnly, @[f("subsystem", vkString, true)], @[objects("units", UnitItemV1)]),
  operation("unit.resolve", idemYes, orGlobal, ocReadOnly, @[f("name", vkString)], @[f("owned", vkBool), f("name", vkString), f("subsystem", vkString)]),
  operation("unit.load", idemYes, orGlobal, ocMutating, results = @[f("loaded", vkInt), coreObjects("errors")]),
  operation("unit.validate", idemYes, orUnit, ocReadOnly, results = @[f("valid", vkBool), coreObjects("diagnostics")]),
  operation("unit.translate", idemYes, orUnit, ocReadOnly, results = @[f("decfile", vkString)]),
  operation("unit.activate", idemNo, orGlobal, ocMutating, results = @[f("started", vkInt), coreObjects("failed")]),
  operation("unit.deactivate", idemNo, orGlobal, ocMutating, results = @[f("stopped", vkInt), coreObjects("failed")]),

  operation("service.start", idemYes, orUnit, ocMutating, results = stateResult),
  operation("service.stop", idemYes, orUnit, ocMutating, results = stateResult),
  operation("service.restart", idemNo, orUnit, ocMutating, results = stateResult),
  operation("service.reload", idemNo, orUnit, ocMutating, results = stateResult),
  operation("service.kill", idemNo, orUnit, ocMutating, @[f("signal", vkString)]),
  operation("service.enable", idemYes, orUnit, ocMutating, enableArgs),
  operation("service.disable", idemYes, orUnit, ocMutating, enableArgs),
  operation("service.status", idemYes, orUnit, ocReadOnly, results = commonStatus &
    @[f("main_pid", vkInt, true), f("pids", vkIntList, true), f("exit_code", vkInt, true)]),

  operation("mount.start", idemYes, orUnit, ocMutating, results = stateResult),
  operation("mount.stop", idemYes, orUnit, ocMutating, @[f("lazy", vkBool)], stateResult),
  operation("mount.enable", idemYes, orUnit, ocMutating, enableArgs),
  operation("mount.disable", idemYes, orUnit, ocMutating, enableArgs),
  operation("mount.status", idemYes, orUnit, ocReadOnly, results = commonStatus &
    @[f("source", vkString), f("target", vkString), f("fstype", vkString)]),

  operation("timer.start", idemYes, orUnit, ocMutating, results = stateResult),
  operation("timer.stop", idemYes, orUnit, ocMutating, results = stateResult),
  operation("timer.enable", idemYes, orUnit, ocMutating, enableArgs),
  operation("timer.disable", idemYes, orUnit, ocMutating, enableArgs),
  operation("timer.status", idemYes, orUnit, ocReadOnly, results = commonStatus &
    @[f("next_run", vkString, true), f("last_run", vkString, true)]),

  operation("socket.start", idemYes, orUnit, ocMutating, results = stateResult),
  operation("socket.stop", idemYes, orUnit, ocMutating, results = stateResult),
  operation("socket.enable", idemYes, orUnit, ocMutating, enableArgs),
  operation("socket.disable", idemYes, orUnit, ocMutating, enableArgs),
  operation("socket.status", idemYes, orUnit, ocReadOnly, results = commonStatus & @[f("listen", vkStringList)]),

  operation("target.start", idemYes, orUnit, ocMutating, results = stateResult),
  operation("target.stop", idemYes, orUnit, ocMutating, results = stateResult),
  operation("target.isolate", idemNo, orUnit, ocMutating, results = stateResult),
  operation("target.enable", idemYes, orUnit, ocMutating, enableArgs),
  operation("target.disable", idemYes, orUnit, ocMutating, enableArgs),
  operation("target.status", idemYes, orUnit, ocReadOnly, results = commonStatus & @[f("members", vkStringList)]),
  operation("target.set-default", idemYes, orUnit, ocMutating),
  operation("target.get-default", idemYes, orGlobal, ocReadOnly, results = @[f("name", vkString)]),

  operation("swap.start", idemYes, orUnit, ocMutating, results = stateResult),
  operation("swap.stop", idemYes, orUnit, ocMutating, results = stateResult),
  operation("swap.enable", idemYes, orUnit, ocMutating, enableArgs),
  operation("swap.disable", idemYes, orUnit, ocMutating, enableArgs),
  operation("swap.status", idemYes, orUnit, ocReadOnly, results = commonStatus &
    @[f("device", vkString), f("priority", vkInt, true)]),

  operation("path.start", idemYes, orUnit, ocMutating, results = stateResult),
  operation("path.stop", idemYes, orUnit, ocMutating, results = stateResult),
  operation("path.enable", idemYes, orUnit, ocMutating, enableArgs),
  operation("path.disable", idemYes, orUnit, ocMutating, enableArgs),
  operation("path.status", idemYes, orUnit, ocReadOnly, results = commonStatus &
    @[f("watches", vkStringList), f("triggers", vkString)]),

  operation("log.read", idemYes, orUnitOrGlobal, ocReadOnly,
    @[f("since", vkString, true), f("until", vkString, true),
      f("lines", vkInt, true, "1000", 1, 10000)], @[objects("entries", LogEntryV1)]),
  operation("log.follow", idemNotApplicable, orUnitOrGlobal, ocStreaming,
    @[f("since", vkString, true)]),
  operation("log.write", idemNo, orUnitOrGlobal, ocMutating,
    @[f("level", vkString), f("message", vkString)]),
  operation("log.rotate", idemNo, orGlobal, ocMutating),
  operation("log.vacuum", idemNo, orGlobal, ocMutating,
    @[f("max_size", vkInt, true), f("max_age", vkString, true)], @[f("freed", vkInt)])
]

proc registry*(manifestVersion: int): seq[OperationSpec] =
  ## Returns a copy so callers cannot mutate the registry shared by others.
  case manifestVersion
  of 1: RegistryV1
  else: raise newException(ValueError, "unsupported manifest version: " & $manifestVersion)

proc findOperation*(manifestVersion: int, name: string): Option[OperationSpec] =
  for spec in registry(manifestVersion):
    if spec.name == name: return some(spec)
  none(OperationSpec)

proc resultField*(manifestVersion: int, operation, field: string): Option[FieldSpec] =
  ## The registry's result field `field` of `operation`.
  let spec = findOperation(manifestVersion, operation)
  if spec.isSome:
    for candidate in spec.get.results:
      if candidate.name == field: return some(candidate)
  none(FieldSpec)

proc logEntryFields*(manifestVersion: int): seq[FieldSpec] =
  ## §12.10 entry shape, also used for streamed `entry` events (§17.4).
  case manifestVersion
  of 1: LogEntryV1
  else: raise newException(ValueError, "unsupported manifest version: " & $manifestVersion)

proc operationsForSubsystem*(manifestVersion: int, subsystem: string): seq[OperationSpec] =
  let prefix = subsystem & "."
  for spec in registry(manifestVersion):
    if spec.name.startsWith(prefix): result.add spec

proc knownSubsystem*(manifestVersion: int, subsystem: string): bool =
  operationsForSubsystem(manifestVersion, subsystem).len != 0

proc isUnitAddressedSubsystem*(subsystem: string): bool = subsystem in UnitAddressedSubsystems
