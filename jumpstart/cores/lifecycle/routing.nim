## Pure state/model layer for unit-reference routing (specification section 14).
##
## This module deliberately performs no I/O and does not wait or invoke a core.
## Callers snapshot core state and unit.resolve replies, call `resolveOwner`, and
## perform any wait or dispatch described by the returned decision.
import std/[algorithm, sets, strutils]
import jumpstartcore/[errors, names]

type
  CoreRuntimeState* = enum
    crUnloaded, crLoading, crLoaded, crUnloading, crFailed, crDegraded

  ResolveReplyKind* = enum
    rrNotCalled, rrAnswered, rrFailed

  ResolveReply* = object
    kind*: ResolveReplyKind
    owned*: bool
    canonicalName*: string
    subsystem*: string
    legacySuffix*: bool       ## Native serviceHandler-only routing hint.
    errorCode*: CoreErrorCode ## Meaningful for rrFailed.
    errorMessage*: string

  NameIndex* = object
    ## `known` distinguishes an empty index from a core which never published.
    known*: bool
    names*: HashSet[string]

  CoreRouteState* = object
    name*: string
    enabled*: bool
    state*: CoreRuntimeState
    nameIndex*: NameIndex
    reply*: ResolveReply

  RouteWarning* = object
    core*: string
    code*: CoreErrorCode
    message*: string

  RouteDecisionKind* = enum
    rdOwner, rdWait

  RouteDecision* = object
    kind*: RouteDecisionKind
    core*: string
    name*: string
    subsystem*: string
    warnings*: seq[RouteWarning]

  UnitCommand* = enum
    ucStart, ucStop, ucRestart, ucReload, ucKill, ucEnable, ucDisable,
    ucStatus, ucIsolate, ucSetDefault, ucValidate, ucTranslate,
    ucLogRead, ucLogFollow, ucLogWrite

  OperationArgument* = object
    name*: string
    value*: string

  OperationMapping* = object
    operation*: string
    arguments*: seq[OperationArgument]

proc initNameIndex*(known = false): NameIndex =
  NameIndex(known: known, names: initHashSet[string]())

proc nameIndex*(names: openArray[string]): NameIndex =
  result = initNameIndex(true)
  for name in names:
    if not validUnitName(name):
      raise newCoreError(ecName, "invalid unit name in name index: " & name)
    result.names.incl(name)

proc replaceNames*(index: var NameIndex; names: openArray[string]) =
  ## Apply a successful unit.list refresh. An empty list is still a known index.
  var replacement = nameIndex(names)
  index = move(replacement)

proc recordOwned*(index: var NameIndex; requested, canonical: string) =
  ## Apply an owned unit.resolve result. Both spellings remain known.
  if not validUnitName(requested) or not validUnitName(canonical):
    raise newCoreError(ecName, "invalid name returned by unit.resolve")
  if not index.known:
    index = initNameIndex(true)
  index.names.incl(requested)
  index.names.incl(canonical)

proc answered*(owned: bool; canonicalName = ""; subsystem = "";
               legacySuffix = false): ResolveReply =
  ResolveReply(kind: rrAnswered, owned: owned, canonicalName: canonicalName,
    subsystem: subsystem, legacySuffix: legacySuffix)

proc failedReply*(code: CoreErrorCode; message = ""): ResolveReply =
  ResolveReply(kind: rrFailed, errorCode: code, errorMessage: message)

proc stateError(state: CoreRuntimeState): CoreErrorCode =
  case state
  of crUnloaded: ecCoreUnloaded
  of crFailed: ecCoreFailed
  of crDegraded: ecDegraded
  of crLoading, crUnloading: ecCoreState
  of crLoaded: ecBackend # never used for a healthy loaded core

proc coreError(core: CoreRouteState; code: CoreErrorCode;
               detail: string): ref CoreError =
  newCoreError(code, detail, core.name)

proc findCore(cores: openArray[CoreRouteState]; name: string): int =
  for i, core in cores:
    if core.name == name: return i
  -1

proc checkedOwner(core: CoreRouteState; requested: string): RouteDecision =
  case core.reply.kind
  of rrNotCalled:
    raise core.coreError(ecCoreState, "unit.resolve has not completed")
  of rrFailed:
    let text = if core.reply.errorMessage.len > 0: core.reply.errorMessage
               else: "unit.resolve failed"
    raise core.coreError(core.reply.errorCode, text)
  of rrAnswered:
    if not core.reply.owned:
      raise core.coreError(ecNotFound, "unit not found: " & requested)
    if not validUnitName(core.reply.canonicalName):
      raise core.coreError(ecProtocol, "unit.resolve returned an invalid canonical name")
    if core.reply.subsystem.len == 0:
      raise core.coreError(ecProtocol, "unit.resolve returned an empty subsystem")
    RouteDecision(kind: rdOwner, core: core.name,
      name: core.reply.canonicalName, subsystem: core.reply.subsystem)

proc resolveOwner*(reference: string; cores: openArray[CoreRouteState];
                   loadingTimedOut = false; callerLoadingCore = ""): RouteDecision =
  ## Resolve entirely from a caller-provided snapshot. `rdWait` means the
  ## daemon should wait for loading to finish and take a new snapshot.
  var unitRef: UnitRef
  try:
    unitRef = parseUnitRef(reference)
  except ValueError as e:
    raise newCoreError(ecName, e.msg)

  if unitRef.qualified:
    let pos = findCore(cores, unitRef.core)
    if pos < 0:
      raise newCoreError(ecNotFound, "core not found: " & unitRef.core, unitRef.core)
    let core = cores[pos]
    if core.state == crLoading:
      if callerLoadingCore == core.name:
        raise core.coreError(ecCoreState, "a loading core cannot route to itself")
      if loadingTimedOut:
        raise core.coreError(ecTimeout, "timed out waiting for core to load")
      return RouteDecision(kind: rdWait)
    if core.state != crLoaded:
      raise core.coreError(stateError(core.state), "core is " &
        ($core.state)[2 .. ^1].toLowerAscii)
    return checkedOwner(core, unitRef.unit)

  # A loading core's own control request does not wait for itself and treats
  # that core as absent. Any other loading participant makes the answer wait.
  for core in cores:
    if core.state == crLoading and core.name != callerLoadingCore:
      if loadingTimedOut:
        raise core.coreError(ecTimeout, "timed out waiting for cores to load")
      return RouteDecision(kind: rdWait)

  var owners: seq[CoreRouteState]
  var unavailable: seq[tuple[core: CoreRouteState, code: CoreErrorCode, message: string]]
  var nativeLegacy = false

  for core in cores:
    if core.name == callerLoadingCore and core.state == crLoading: continue
    case core.state
    of crLoaded:
      case core.reply.kind
      of rrAnswered:
        if core.reply.owned:
          owners.add(core)
          if core.name == "serviceHandler" and core.reply.legacySuffix:
            nativeLegacy = true
      of rrFailed:
        unavailable.add((core, core.reply.errorCode,
          if core.reply.errorMessage.len > 0: core.reply.errorMessage else: "unit.resolve failed"))
      of rrNotCalled:
        unavailable.add((core, ecCoreState, "unit.resolve has not completed"))
    of crDegraded:
      unavailable.add((core, ecDegraded, "core is degraded"))
    of crFailed:
      if core.enabled: unavailable.add((core, ecCoreFailed, "core failed to load"))
    of crUnloaded:
      if core.enabled: unavailable.add((core, ecCoreUnloaded, "core is not loaded"))
    of crLoading, crUnloading:
      discard

  # Unavailable cores never cause fallback for names they are known to own.
  # The legacy native heuristic applies only when an unavailable core has no
  # index at all, not when it has a known-empty index.
  for item in unavailable:
    let blocks = (item.core.nameIndex.known and
                    unitRef.unit in item.core.nameIndex.names) or
                 (not item.core.nameIndex.known and nativeLegacy)
    if blocks:
      raise item.core.coreError(item.code, item.message &
        "; use a qualified reference for " & item.core.name & "/" & unitRef.unit)
    result.warnings.add RouteWarning(core: item.core.name, code: item.code,
      message: item.message)

  if owners.len == 0:
    raise newCoreError(ecNotFound, "unit not found: " & unitRef.unit)
  if owners.len > 1:
    var alternatives: seq[string]
    for owner in owners:
      let canonical = if owner.reply.canonicalName.len > 0:
                        owner.reply.canonicalName else: unitRef.unit
      alternatives.add(owner.name & "/" & canonical)
    alternatives.sort(system.cmp[string])
    raise newCoreError(ecAmbiguous,
      "unit is ambiguous; use one of: " & alternatives.join(", "))

  let owner = owners[0]
  if not validUnitName(owner.reply.canonicalName):
    raise owner.coreError(ecProtocol, "unit.resolve returned an invalid canonical name")
  if owner.reply.subsystem.len == 0:
    raise owner.coreError(ecProtocol, "unit.resolve returned an empty subsystem")
  result.kind = rdOwner
  result.core = owner.name
  result.name = owner.reply.canonicalName
  result.subsystem = owner.reply.subsystem

proc commandFromString*(action: string): UnitCommand =
  case action
  of "start": ucStart
  of "stop": ucStop
  of "restart": ucRestart
  of "reload": ucReload
  of "kill": ucKill
  of "enable": ucEnable
  of "disable": ucDisable
  of "status": ucStatus
  of "isolate": ucIsolate
  of "set-default": ucSetDefault
  of "validate": ucValidate
  of "translate": ucTranslate
  of "log-read": ucLogRead
  of "log-follow": ucLogFollow
  of "log-write": ucLogWrite
  else: raise newCoreError(ecUsage, "unknown unit action: " & action)

proc mapOperation*(subsystem: string; command: UnitCommand;
                   signal = ""; now = false; target = "";
                   extraArguments: openArray[OperationArgument] = []): OperationMapping =
  ## Map only; registry support is intentionally checked by the dispatch layer.
  if subsystem.len == 0:
    raise newCoreError(ecProtocol, "resolved unit has no subsystem")
  case command
  of ucStart: result.operation = subsystem & ".start"
  of ucStop:
    result.operation = subsystem & ".stop"
    if subsystem == "mount":
      result.arguments.add OperationArgument(name: "lazy", value: "false")
  of ucRestart: result.operation = "service.restart"
  of ucReload: result.operation = "service.reload"
  of ucKill:
    result.operation = "service.kill"
    result.arguments.add OperationArgument(name: "signal",
      value: if signal.len == 0: "SIGTERM" else: signal)
  of ucEnable, ucDisable:
    result.operation = subsystem & (if command == ucEnable: ".enable" else: ".disable")
    if target.len > 0 and not validUnitName(target):
      raise newCoreError(ecName, "target must be a bare unit name")
    result.arguments.add OperationArgument(name: "now", value: $now)
    if target.len > 0:
      result.arguments.add OperationArgument(name: "target", value: target)
  of ucStatus: result.operation = subsystem & ".status"
  of ucIsolate: result.operation = "target.isolate"
  of ucSetDefault: result.operation = "target.set-default"
  of ucValidate: result.operation = "unit.validate"
  of ucTranslate: result.operation = "unit.translate"
  of ucLogRead: result.operation = "log.read"
  of ucLogFollow: result.operation = "log.follow"
  of ucLogWrite: result.operation = "log.write"
  for argument in extraArguments: result.arguments.add(argument)

proc mapOperation*(subsystem, action: string; signal = ""; now = false;
                   target = "";
                   extraArguments: openArray[OperationArgument] = []): OperationMapping =
  mapOperation(subsystem, commandFromString(action), signal, now, target,
    extraArguments)

proc mapGlobalOperation*(action: string): string =
  case action
  of "get-default": "target.get-default"
  of "log-read": "log.read"
  of "log-follow": "log.follow"
  of "log-write": "log.write"
  else: raise newCoreError(ecUsage, "unknown global action: " & action)
