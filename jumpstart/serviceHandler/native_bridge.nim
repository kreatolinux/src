## serviceHandler's native backend (§13.6, Appendix A).
##
## `NativeBridge` is the single entry point the daemon uses for the built-in
## core: `resolve` answers `unit.resolve` (with the internal legacy-suffix
## hint, §14.3) and `dispatch` performs every operation Appendix A marks
## `native`, returning results shaped as in the registry (§12). Failures raise
## `CoreError` with the §18 code. All calls are made from the daemon thread;
## process exits arrive through the central reaper (§15.3).
import std/[algorithm, json, os, sets, strutils, tables, times]
import ../../common/logging
import ../[configParser, unitname]
import std/options
import ../cores/native/[native_api, native_targets],
  ../cores/lifecycle/routing,
  ../cores/manifest/types
import jumpstartcore/[cgroups, errors]
import globalVariables, start, stop, status, status_text
import jumpmount/main as jumpmount
import jumpmount/umount
import jumptimer/main as jumptimer
import jumptimer/stop as jumptimerstop

export globalVariables, status_text

type
  NativeBridge* = ref object
    ctx*: NativeContext
    model*: NativeTargetModel
    loadErrors*: seq[NativeDiagnostic]
    mtimes: Table[string, Time]
    startHistory*: seq[string]      ## Every native start, in order.
    startedTargets*: Table[string, int] ## Target -> sequence of its last start.
    startFailures*: Table[string, string] ## Last start attempt failed.
    clientVersion*: string

proc fail(code: CoreErrorCode; message: string) {.noreturn.} =
  raise newCoreError(code, message, "serviceHandler")

proc coreCode(code: string): CoreErrorCode =
  case code
  of "E_NAME": ecName
  of "E_UNIT_NOT_FOUND", "E_NOT_FOUND": ecNotFound
  of "E_UNSUPPORTED": ecUnsupported
  else: ecUnitState

proc convertError(e: ref NativeTargetError) {.noreturn.} =
  fail(coreCode(e.code), e.msg)

proc diagnosticJson(item: NativeDiagnostic): JsonNode =
  %* {"name": item.name, "code": item.code, "message": item.message}

# --- unit definitions --------------------------------------------------------

proc nativeKind(config: UnitConfig): NativeUnitKind =
  case config.unitType
  of utSimple, utOneshot: nukService
  of utMount: nukMount
  of utTimer: nukTimer
  of utTarget: nukTarget
  of utMulti: nukMulti

proc nativeUnitOf(config: UnitConfig; name: string): NativeUnit =
  result = NativeUnit(name: name, kind: nativeKind(config), wants: config.wants,
    depends: config.depends, after: config.after,
    subDepends: config.subDepends, subAfter: config.subAfter,
    oneshot: config.unitType == utOneshot)
  if config.unitType == utMulti:
    for item in config.mounts:
      result.members.add(name & "::" & item.name); result.memberKinds.add(nukMount)
    for item in config.services:
      result.members.add(name & "::" & item.name); result.memberKinds.add(nukService)
    for item in config.timers:
      result.members.add(name & "::" & item.name); result.memberKinds.add(nukTimer)

proc decfilePath(bridge: NativeBridge; name: string): string =
  bridge.ctx.configRoot / (name & ".kg")

proc decfileTime(path: string): Time =
  try: getLastModificationTime(path) except CatchableError: Time()

proc parseInto(bridge: NativeBridge; name: string;
               errors: var seq[NativeDiagnostic]): bool =
  ## Parse one decfile into the model. Returns false when it is not loaded.
  try:
    let config = parseUnit(bridge.ctx.configRoot, name)
    for message in unitDiagnostics(config):
      errors.add NativeDiagnostic(name: name, code: "E_UNIT_STATE", message: message)
    bridge.model.units.del(name)
    bridge.model.addUnit(nativeUnitOf(config, name))
    bridge.mtimes[name] = decfileTime(bridge.decfilePath(name))
    true
  except NativeTargetError as e:
    errors.add NativeDiagnostic(name: name, code: e.code, message: e.msg)
    false
  except CatchableError as e:
    errors.add NativeDiagnostic(name: name, code: "E_UNIT_STATE", message: e.msg)
    false

proc reload*(bridge: NativeBridge): JsonNode =
  ## `unit.load`: reread every decfile. Starts and stops nothing.
  bridge.model = initNativeTargetModel(bridge.ctx.configRoot)
  bridge.mtimes = initTable[string, Time]()
  var errors: seq[NativeDiagnostic]
  var loaded = 0
  var names = getAllUnitsInDir(bridge.ctx.configRoot)
  names.sort(system.cmp[string])
  for name in names:
    if name == BuiltinDefaultTarget: continue # reported by validationErrors
    if bridge.parseInto(name, errors): inc loaded
  for item in bridge.model.validationErrors(): errors.add item
  bridge.loadErrors = errors
  var list = newJArray()
  for item in errors: list.add diagnosticJson(item)
  %* {"loaded": loaded, "errors": list}

proc refresh(bridge: NativeBridge; base: string) =
  ## Keep the loaded definition of one decfile current: decfiles have always
  ## been usable as soon as they exist, without a reload.
  if base.len == 0 or base == BuiltinDefaultTarget: return
  let path = bridge.decfilePath(base)
  if not (fileExists(path) or symlinkExists(path)):
    bridge.model.units.del(base)
    bridge.mtimes.del(base)
    return
  if bridge.model.units.hasKey(base) and
      bridge.mtimes.getOrDefault(base) == decfileTime(path):
    return
  var ignored: seq[NativeDiagnostic]
  if not bridge.parseInto(base, ignored): bridge.model.units.del(base)

proc newNativeBridge*(ctx: NativeContext; resetRuntime = false;
                      clientVersion = "jumpstart"): NativeBridge =
  ## `resetRuntime` empties the runtime directory, as daemon startup always
  ## has; unit.load never does.
  result = NativeBridge(ctx: ctx, clientVersion: clientVersion,
    startedTargets: initTable[string, int](),
    startFailures: initTable[string, string]())
  if resetRuntime and dirExists(ctx.runtimeRoot):
    try: removeDir(ctx.runtimeRoot)
    except CatchableError as e: warn "Could not reset native runtime state: " & e.msg
  try: createDir(ctx.runtimeRoot)
  except CatchableError as e: warn "Could not create native runtime state: " & e.msg
  discard result.reload()

proc logLoadErrors*(bridge: NativeBridge) =
  for item in bridge.loadErrors:
    error "serviceHandler: " & item.code & ": " &
      (if item.name.len > 0: item.name & ": " else: "") & item.message

# --- resolution --------------------------------------------------------------

proc resolve*(bridge: NativeBridge; requested: string): ResolveReply =
  ## `unit.resolve`. Accepts a decfile name with an optional `::` sub-unit and
  ## the legacy suffixes `.kg`, `.service`, `.mount` and `.timer`; reports via
  ## `legacySuffix` whether the match relied on stripping one (§14.3).
  if requested.len == 0: return answered(false)
  if requested == BuiltinDefaultTarget:
    return answered(true, BuiltinDefaultTarget, "target")
  bridge.refresh(definitionName(requested))
  if bridge.model.hasUnit(requested):
    return answered(true, requested, bridge.model.subsystem(requested))
  let normalized = normalizeUnitName(requested)
  if normalized == requested: return answered(false)
  if normalized == BuiltinDefaultTarget:
    return answered(true, BuiltinDefaultTarget, "target", legacySuffix = true)
  bridge.refresh(definitionName(normalized))
  if bridge.model.hasUnit(normalized):
    return answered(true, normalized, bridge.model.subsystem(normalized),
                    legacySuffix = true)
  answered(false)

# --- state -------------------------------------------------------------------

proc enablementName(value: NativeEnablement): string =
  case value
  of neDisabled: "disabled"
  of neStatic: "static"
  of neEnabled: "enabled"

proc enablementOf(bridge: NativeBridge; name: string): string =
  if name == BuiltinDefaultTarget: return "static"
  enablementName(bridge.model.enablement(name))

proc activeUnits*(bridge: NativeBridge): seq[string] =
  ## Every active native unit, however it was started.
  let ctx = bridge.ctx
  for name, record in ctx.services:
    if record.running or record.postRunning: result.add(name)
  let mounts = ctx.runtimeRoot / "mounts"
  if dirExists(mounts):
    for kind, path in walkDir(mounts):
      if kind == pcDir: result.add(extractFilename(path))
  for timer in ctx.timers: result.add(timer.timerName)
  result.sort(system.cmp[string])

proc unitStatus(bridge: NativeBridge; name, subsystem: string): JsonNode

proc nestedTargets(bridge: NativeBridge; target: string): seq[string] =
  ## The target and every target reachable through its membership.
  var seen = initHashSet[string]()
  var pending = @[target]
  while pending.len > 0:
    let name = pending.pop()
    if name in seen or not bridge.model.isTarget(name): continue
    seen.incl(name); result.add(name)
    for member in bridge.model.directMembers(name): pending.add(member)

proc isOneshot(bridge: NativeBridge; name: string): bool =
  not isSubUnit(name) and bridge.model.units.hasKey(name) and
    bridge.model.units[name].oneshot

proc targetStatus(bridge: NativeBridge; target: string): JsonNode =
  ## §22.5 target and multi-unit status.
  var members: seq[string]
  try: members = bridge.model.transitiveMembers(target)
  except NativeTargetError as e: convertError(e)
  let started = bridge.startedTargets.hasKey(target)
  let since = bridge.startedTargets.getOrDefault(target, high(int))
  var satisfied = 0
  var failed = false
  for name in members:
    if bridge.startFailures.hasKey(name) or not bridge.model.hasUnit(name):
      failed = true; continue # failed to start, or an unknown member
    let state = bridge.unitStatus(name, bridge.model.subsystem(name)){"state"}.getStr
    if state == "failed": failed = true
    elif state == "active": inc satisfied
    elif bridge.isOneshot(name):
      let record = bridge.ctx.findService(name)
      if not record.isNil and not record.running and record.exitCode == 0 and
          record.startSeq > since:
        inc satisfied
  let state = if failed: "failed"
    elif started and satisfied == members.len: "active"
    elif not started or satisfied == 0: "inactive"
    else: "activating"
  %* {"state": state,
      "detail": $satisfied & " of " & $members.len & " members satisfied",
      "enablement": bridge.enablementOf(target), "members": members}

proc unitStatus(bridge: NativeBridge; name, subsystem: string): JsonNode =
  case subsystem
  of "service": result = bridge.ctx.serviceStatus(name)
  of "mount": result = bridge.ctx.mountStatus(name)
  of "timer": result = bridge.ctx.timerStatus(name)
  of "target": return bridge.targetStatus(name)
  else: fail(ecUnsupported, "unknown native subsystem: " & subsystem)
  result["enablement"] = %bridge.enablementOf(name)

# --- start and stop ----------------------------------------------------------

proc recordStart(bridge: NativeBridge; name: string) =
  let at = bridge.startHistory.find(name)
  if at >= 0: bridge.startHistory.delete(at)
  bridge.startHistory.add(name)
  bridge.startFailures.del(name)

proc startOne(bridge: NativeBridge; name, subsystem: string) =
  ## Start one non-target unit, without its dependencies.
  try:
    case subsystem
    of "service": bridge.ctx.startService(name)
    of "mount": bridge.ctx.startMount(name)
    of "timer": bridge.ctx.startTimer(name, bridge.clientVersion)
    else: fail(ecUnsupported, "cannot start " & subsystem & " unit " & name)
  except CoreError as e:
    bridge.startFailures[name] = e.msg
    raise
  bridge.recordStart(name)

proc stopOne(bridge: NativeBridge; name, subsystem: string; lazy = false) =
  case subsystem
  of "service": bridge.ctx.stopService(name)
  of "mount": bridge.ctx.stopMount(name, lazy)
  of "timer": bridge.ctx.stopTimer(name)
  else: fail(ecUnsupported, "cannot stop " & subsystem & " unit " & name)
  bridge.startFailures.del(name)

proc failureJson(name, code, message: string): JsonNode =
  %* {"name": name, "code": code, "message": message}

proc reachTarget(bridge: NativeBridge; target: string;
                 failed: var seq[JsonNode]): int =
  ## Start every member of `target`, transitively, with their `depends`
  ## closure, ordered by `depends` and `after` (§22.5). Returns how many
  ## units were started; failures are appended to `failed`.
  var report: ActivationReport
  try: report = bridge.model.activationReport(target)
  except NativeTargetError as e: convertError(e)
  let sequence = bridge.ctx.nextSequence()
  for nested in bridge.nestedTargets(target):
    bridge.startedTargets[nested] = sequence
  var broken = initHashSet[string]()
  for item in report.failed:
    broken.incl(item.name)
    bridge.startFailures[item.name] = item.message
    failed.add failureJson(item.name, item.code, item.message)
  for name in report.plan:
    var blocked = ""
    for dep in bridge.model.hardDependencies(name):
      if dep in broken: blocked = dep
    if blocked.len > 0:
      broken.incl(name)
      let message = "dependency " & blocked & " failed to start"
      bridge.startFailures[name] = message
      failed.add failureJson(name, "E_UNIT_STATE", message)
      continue
    try:
      bridge.startOne(name, bridge.model.subsystem(name))
      inc result
    except CoreError as e:
      broken.incl(name)
      failed.add failureJson(name, errorName(e.code), e.msg)

proc partial(what: string; failed: seq[JsonNode]) {.noreturn.} =
  var parts: seq[string]
  for item in failed: parts.add(item["name"].getStr & ": " & item["message"].getStr)
  fail(ecPartial, what & ": " & parts.join("; "))

proc stopUnits(bridge: NativeBridge; names: seq[string];
               failed: var seq[JsonNode]): int =
  for name in names:
    let subsystem = bridge.model.subsystem(name)
    try:
      if subsystem.len == 0:
        # The decfile is gone; stop what is still known to be running.
        if bridge.ctx.findService(name) != nil: bridge.ctx.stopService(name)
        elif bridge.ctx.findTimerIndex(name) >= 0: bridge.ctx.stopTimer(name)
        elif bridge.ctx.mountActive(name):
          fail(ecNotFound, "decfile of mount " & name & " no longer exists")
      else:
        bridge.stopOne(name, subsystem)
      inc result
      let at = bridge.startHistory.find(name)
      if at >= 0: bridge.startHistory.delete(at)
    except CoreError as e:
      failed.add failureJson(name, errorName(e.code), e.msg)

proc startTarget(bridge: NativeBridge; target: string): JsonNode =
  var failed: seq[JsonNode]
  discard bridge.reachTarget(target, failed)
  if failed.len > 0: partial("target " & target & " started partially", failed)
  %* {"state": bridge.targetStatus(target)["state"]}

proc stopTarget(bridge: NativeBridge; target: string): JsonNode =
  var plan: seq[string]
  try:
    plan = bridge.model.deactivationPlanForTarget(target, bridge.startHistory,
                                                  bridge.activeUnits())
  except NativeTargetError as e: convertError(e)
  var failed: seq[JsonNode]
  discard bridge.stopUnits(plan, failed)
  for nested in bridge.nestedTargets(target): bridge.startedTargets.del(nested)
  if failed.len > 0: partial("target " & target & " stopped partially", failed)
  %* {"state": bridge.targetStatus(target)["state"]}

proc isolate(bridge: NativeBridge; target: string): JsonNode =
  ## Start `target`, then stop every active native unit it does not require
  ## (its transitive members and their `depends` closure).
  var failed: seq[JsonNode]
  discard bridge.reachTarget(target, failed)
  let keep = bridge.model.requiredUnits(target)
  var outsiders: seq[string]
  for name in deactivationPlan(bridge.startHistory, bridge.activeUnits()):
    if name notin keep: outsiders.add(name)
  discard bridge.stopUnits(outsiders, failed)
  let reached = bridge.nestedTargets(target)
  var others: seq[string]
  for name in bridge.startedTargets.keys:
    if name notin reached: others.add(name)
  for name in others: bridge.startedTargets.del(name)
  if failed.len > 0: partial("isolate " & target & " completed partially", failed)
  %* {"state": bridge.targetStatus(target)["state"]}

proc activate*(bridge: NativeBridge): JsonNode =
  ## `unit.activate`: start the boot target (§22.3, §22.5).
  var failed: seq[JsonNode]
  var started = 0
  var target = ""
  try:
    target = bridge.model.getDefaultTarget()
    info "Starting boot target " & target
    started = bridge.reachTarget(target, failed)
  except NativeTargetError as e:
    failed.add failureJson((if target.len > 0: target else: "default-target"),
                           e.code, e.msg)
  except CoreError as e:
    failed.add failureJson(target, errorName(e.code), e.msg)
  for item in failed:
    warn "Failed to start " & item["name"].getStr & ": " & item["message"].getStr
  %* {"started": started, "failed": failed}

proc deactivate*(bridge: NativeBridge): JsonNode =
  ## `unit.deactivate`: stop every active native unit, in reverse start order.
  var failed: seq[JsonNode]
  let stopped = bridge.stopUnits(
    deactivationPlan(bridge.startHistory, bridge.activeUnits()), failed)
  bridge.startedTargets.clear()
  %* {"stopped": stopped, "failed": failed}

# --- other operations --------------------------------------------------------

proc unitList(bridge: NativeBridge; subsystem: string): JsonNode =
  var names: seq[string]
  for name in getAllUnitsInDir(bridge.ctx.configRoot):
    if name != BuiltinDefaultTarget: bridge.refresh(name)
  var known: seq[string]
  for name in bridge.model.units.keys: known.add(name)
  for name in known: bridge.refresh(name) # drops deleted decfiles
  for name in bridge.model.units.keys: names.add(name)
  names.sort(system.cmp[string])
  names.insert(BuiltinDefaultTarget, 0)
  var listed: seq[string]
  for name in names:
    listed.add(name)
    if name != BuiltinDefaultTarget and bridge.model.units[name].kind == nukMulti:
      for child in bridge.model.units[name].members: listed.add(child)
  var units = newJArray()
  for name in listed:
    let sub = bridge.model.subsystem(name)
    if subsystem.len == 0 or subsystem == sub:
      units.add(%* {"name": name, "subsystem": sub,
                    "enablement": bridge.enablementOf(name)})
  %* {"units": units}

proc validateOne(bridge: NativeBridge; name: string): JsonNode =
  ## `unit.validate`: one decfile's problems. A reserved `default.kg` is only
  ## reported for `default` itself, never for unrelated units.
  var found: seq[NativeDiagnostic]
  template add(item: NativeDiagnostic) = found.add(item)
  let base = definitionName(name)
  if base == BuiltinDefaultTarget:
    if bridge.model.reservedDefaultPresent: add(reservedDefaultDiagnostic())
  else:
    try:
      let config = parseUnit(bridge.ctx.configRoot, base)
      for message in unitDiagnostics(config):
        add NativeDiagnostic(name: base, code: "E_UNIT_STATE", message: message)
    except CatchableError as e:
      add NativeDiagnostic(name: base, code: "E_UNIT_STATE", message: e.msg)
  if not isSubUnit(name) and bridge.model.isTarget(name):
    for item in bridge.model.targetDiagnostics(name): add(item)
    let cycle = bridge.model.targetCycle()
    if name in cycle:
      add NativeDiagnostic(name: name, code: "E_UNIT_STATE",
        message: "native target cycle: " & cycle.join(" -> "))
  var diagnostics = newJArray()
  for item in found: diagnostics.add diagnosticJson(item)
  %* {"valid": found.len == 0, "diagnostics": diagnostics}

proc boolArg(args: JsonNode; name: string): bool =
  if args.isNil or args.kind != JObject or not args.hasKey(name): return false
  let value = args[name]
  case value.kind
  of JBool: value.getBool
  of JString:
    case value.getStr
    of "true": true
    of "false", "": false
    else: fail(ecUsage, name & " must be a boolean")
  else: fail(ecUsage, name & " must be a boolean")

proc strArg(args: JsonNode; name: string; default = ""): string =
  if args.isNil or args.kind != JObject or not args.hasKey(name): return default
  if args[name].kind != JString: fail(ecUsage, name & " must be a string")
  args[name].getStr

proc setEnablement(bridge: NativeBridge; name, subsystem: string;
                   args: JsonNode; enable: bool) =
  if isSubUnit(name):
    fail(ecUnsupported, "sub-unit " & name & " cannot be " &
      (if enable: "enabled" else: "disabled") & " on its own; " &
      (if enable: "enable" else: "disable") & " decfile " & definitionName(name) &
      " or list " & name & " in a target's wants")
  if name == BuiltinDefaultTarget:
    fail(ecUnitState, "the built-in default target cannot be enabled or disabled")
  var target = strArg(args, "target", BuiltinDefaultTarget)
  if target.len == 0: target = BuiltinDefaultTarget
  if target != BuiltinDefaultTarget:
    let reply = bridge.resolve(target)
    if not reply.owned or reply.subsystem != "target":
      fail(ecNotFound, "not a native target: " & target)
    target = reply.canonicalName
  let now = boolArg(args, "now")
  try:
    if enable: bridge.model.enable(name, target)
    else: bridge.model.disable(name, target)
  except NativeTargetError as e: convertError(e)
  except CatchableError as e: fail(ecIo, e.msg)
  if enable: ok "Enabled " & name
  else: ok "Disabled unit " & name
  if now:
    if enable:
      if subsystem == "target": discard bridge.startTarget(name)
      else: bridge.startOne(name, subsystem)
    else:
      if subsystem == "target": discard bridge.stopTarget(name)
      else:
        bridge.stopOne(name, subsystem)
        let at = bridge.startHistory.find(name)
        if at >= 0: bridge.startHistory.delete(at)

proc stateOf(bridge: NativeBridge; name, subsystem: string): JsonNode =
  %* {"state": bridge.unitStatus(name, subsystem)["state"]}

proc dispatch*(bridge: NativeBridge; operation, unit: string;
               args: JsonNode = nil): JsonNode =
  ## Perform one native operation. `unit` is the canonical name from
  ## `resolve` for unit-routed operations and is ignored for global ones.
  let args = if args.isNil: newJObject() else: args
  bridge.ctx.pump() # deliver exits the reaper has not handed out yet
  try:
    case operation
    of "unit.list": return bridge.unitList(strArg(args, "subsystem"))
    of "unit.resolve":
      let reply = bridge.resolve(strArg(args, "name", unit))
      return %* {"owned": reply.owned, "name": reply.canonicalName,
                 "subsystem": reply.subsystem}
    of "unit.load":
      result = bridge.reload()
      bridge.logLoadErrors()
      return
    of "unit.activate": return bridge.activate()
    of "unit.deactivate": return bridge.deactivate()
    of "target.get-default":
      return %* {"name": bridge.model.getDefaultTarget()}
    of "unit.translate":
      fail(ecUnsupported, "native units are already decfiles")
    of "service.reload":
      fail(ecUnsupported, "decfiles have no reload command")
    else: discard

    let reply = bridge.resolve(unit)
    if not reply.owned: fail(ecNotFound, "native unit not found: " & unit)
    let name = reply.canonicalName
    let subsystem = reply.subsystem
    if operation == "unit.validate": return bridge.validateOne(name)
    let dot = operation.find('.')
    let opSubsystem = if dot < 0: "" else: operation[0 ..< dot]
    let verb = if dot < 0: operation else: operation[dot + 1 .. ^1]
    if opSubsystem != subsystem:
      fail(ecUnsupported, operation & " is not defined for " & subsystem &
        " unit " & name)
    case verb
    of "start":
      if subsystem == "target": return bridge.startTarget(name)
      bridge.startOne(name, subsystem)
      return bridge.stateOf(name, subsystem)
    of "stop":
      if subsystem == "target": return bridge.stopTarget(name)
      bridge.stopOne(name, subsystem, lazy = boolArg(args, "lazy"))
      let at = bridge.startHistory.find(name)
      if at >= 0: bridge.startHistory.delete(at)
      return bridge.stateOf(name, subsystem)
    of "restart":
      bridge.stopOne(name, subsystem)
      bridge.startOne(name, subsystem)
      return bridge.stateOf(name, subsystem)
    of "kill":
      bridge.ctx.killService(name, strArg(args, "signal", "SIGTERM"))
      return newJObject()
    of "enable", "disable":
      bridge.setEnablement(name, subsystem, args, verb == "enable")
      return newJObject()
    of "status": return bridge.unitStatus(name, subsystem)
    of "isolate": return bridge.isolate(name)
    of "set-default":
      bridge.model.setDefaultTarget(name)
      return newJObject()
    else: fail(ecUnsupported, "native operation is not implemented: " & operation)
  except NativeTargetError as e: convertError(e)

# --- daemon integration ------------------------------------------------------

proc unitSnapshots*(bridge: NativeBridge): seq[UnitSnapshot] =
  ## Active native units with their state, for busy checks and listings.
  bridge.ctx.pump()
  for name in bridge.activeUnits():
    result.add UnitSnapshot(name: name,
      enabled: bridge.model.hasUnit(name) and
        bridge.model.enablement(name) == neEnabled,
      state: ursActive)

proc busy*(bridge: NativeBridge): BusySnapshot =
  ## serviceHandler's per-unit cgroups are below its core cgroup; the daemon
  ## inspects that cgroup itself, so only units are reported here.
  BusySnapshot(cgroupAvailable: false, cgroupPopulated: false,
               units: bridge.unitSnapshots())

proc callbacks*(bridge: NativeBridge): ServiceHandlerCallbacks =
  ## Daemon callbacks for an existing bridge. `load` rereads the definitions
  ## and reports their errors (including a reserved `default.kg`) but starts
  ## nothing: the daemon dispatches `unit.activate` (activation: core).
  ServiceHandlerCallbacks(
    load: proc(cgroups: Option[CoreCgroups]) =
      bridge.ctx.cgroups = cgroups
      discard bridge.reload()
      bridge.logLoadErrors(),
    resolve: proc(name: string): ResolveReply = bridge.resolve(name),
    dispatch: proc(operation, unit: string; args: JsonNode): JsonNode =
      bridge.dispatch(operation, unit, args),
    units: proc(): seq[UnitSnapshot] = bridge.unitSnapshots())

proc serviceHandlerCallbacks*(ctx: NativeContext; clientVersion: string;
                              onCreate: proc(bridge: NativeBridge) {.closure.} = nil):
                              ServiceHandlerCallbacks =
  ## Daemon callbacks that create the bridge at the first load (§20.3: the
  ## existing service-handler initialization, which empties the native
  ## runtime directory) and reread decfiles on later loads.
  var bridge: NativeBridge = nil
  ServiceHandlerCallbacks(
    load: proc(cgroups: Option[CoreCgroups]) =
      ctx.cgroups = cgroups
      if bridge.isNil:
        bridge = newNativeBridge(ctx, resetRuntime = true, clientVersion = clientVersion)
        if not onCreate.isNil: onCreate(bridge)
      else:
        discard bridge.reload()
      bridge.logLoadErrors(),
    resolve: proc(name: string): ResolveReply =
      if bridge.isNil: answered(false) else: bridge.resolve(name),
    dispatch: proc(operation, unit: string; args: JsonNode): JsonNode =
      if bridge.isNil: raise newCoreError(ecCoreUnloaded, "serviceHandler is not loaded")
      bridge.dispatch(operation, unit, args),
    units: proc(): seq[UnitSnapshot] =
      if bridge.isNil: @[] else: bridge.unitSnapshots())
