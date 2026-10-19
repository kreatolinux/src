## Request routing (§14.3): qualified and unqualified unit requests, global
## operations and their fan-out, parked requests and resolution.
import std/[algorithm, deques, json, monotimes, options, os, posix, sets, strutils,
  tables]
import ../backends/[adapter, adapter_runtime, backend_runtime, extension_runtime, supervisor_runtime],
  ../manifest/[coredirs, discovery, manifest, modes, types],
  ./[control, control_transport, core_host, logging, server, shutdown, shutdown_linux],
  ../lifecycle/[dispatch, lifecycle, lifecycle_exec, routing, runtime_resources, state],
  ../native/native_api,
  ../sessions/[session_manager, sessions]
import jumpstartcore/[cgroups, environment, errors, names, peercred, protocol, reaper, registry]
import ../manifest/nameindex as nameidx
import ../lifecycle/resources as res
import jumpstartcore/registry_types as regtypes
import ./daemon_state
import ./daemon_calls
import ./daemon_events

# ---------------------------------------------------------------------------
# Routing (§14.3) and request handling

proc respond*(d: Daemon; job: Job; response: ControlResponse) =
  if job.done: return
  d.log(clDebug, "", "response to pid " & $job.peer.pid & ": " &
    (if response.status == rsOk: "ok"
     else: errorName(response.error.code) & " " & response.error.message))
  job.done = true
  job.parked = false
  job.ctx.complete(response)

proc respondError*(d: Daemon; job: Job; e: ref CoreError) =
  d.respond(job, errorResponse(e.code, e.msg, e.core))

proc anyLoading*(d: Daemon; except_core = ""): bool =
  ## Whether an unqualified request must wait (§14.3). A request from a
  ## loading core's own `init` never waits: lifecycle procedures run one at a
  ## time, so every other core is either loaded already (its delegation
  ## targets) or queued behind the caller, and waiting would deadlock.
  if except_core.len > 0: return false
  for core in d.registry.cores:
    if core.state == csLoading and core.name != except_core: return true
  for name in d.startupPending:
    if name != except_core: return true

proc coreLoading*(d: Daemon; core: string): bool =
  d.stateOf(core) == csLoading or core in d.startupPending

proc processCgroup*(d: Daemon; pid: int64): string =
  try:
    for line in readFile(d.config.procRoot / $pid / "cgroup").splitLines:
      if line.startsWith("0::"): return line[3 .. ^1]
  except CatchableError: discard

proc parentPid*(d: Daemon; pid: int): int =
  try:
    let text = readFile(d.config.procRoot / $pid / "stat")
    let close = text.rfind(')')
    let fields = text[close + 2 .. ^1].splitWhitespace()
    parseInt(fields[1])
  except CatchableError: 0

proc callerLoadingCore*(d: Daemon; job: Job): string =
  ## §14.3: a request from a process in a loading core's `control/` cgroup
  ## (such as `jumpctl` in that core's `init`) does not wait for that core.
  if job.callerKnown: return job.callerCore
  job.callerKnown = true
  if job.peer.pid <= 0: return ""
  let cg = d.processCgroup(job.peer.pid)
  var loading: seq[string]
  for core in d.registry.cores:
    if core.state == csLoading: loading.add core.name
  for name in loading:
    if d.host.hasCgroup(name):
      let control = d.host.layout(name).control
      var rel = control
      if rel.startsWith(d.config.cgroupMount): rel = rel[d.config.cgroupMount.len .. ^1]
      if cg.len > 0 and (cg == rel or cg.startsWith(rel & "/")):
        job.callerCore = name
        return name
  # Without a matching cgroup, a descendant of a process Jumpstart runs for
  # the loading core (its `init` runner) is that core's caller too.
  var owners = initTable[int, string]()
  for (process, pid) in d.driver.liveProcesses():
    let core = coreOfAdapter(process)
    if core in loading: owners[int(pid)] = core
  var pid = int(job.peer.pid)
  var hops = 0
  while pid > 1 and hops < 64:
    if owners.hasKey(pid):
      job.callerCore = owners[pid]
      return job.callerCore
    pid = d.parentPid(pid)
    inc hops
  ""

proc park*(d: Daemon; job: Job; core: string; resume: proc() {.closure.}) =
  if not job.parked:
    d.log(clDebug, "", "request from pid " & $job.peer.pid & " waits for " &
      (if core.len > 0: core else: "loading cores"))
  job.parked = true
  job.parkCore = core
  job.resume = resume
  if job notin d.jobs: d.jobs.add job

proc boolArg*(value: JsonNode): Option[bool] =
  if value.isNil: return none(bool)
  case value.kind
  of JBool: some(value.getBool)
  of JString:
    case value.getStr.toLowerAscii
    of "true": some(true)
    of "false": some(false)
    else: none(bool)
  else: none(bool)

proc coerceArguments*(operation: string; args: JsonNode): JsonNode =
  ## Registry argument types (§12): legacy clients send strings for booleans.
  result = if args.isNil: newJObject() else: args.copy
  let spec = findOperation(CurrentManifestVersion, operation)
  if spec.isNone: return
  for field in spec.get.arguments:
    if not result.hasKey(field.name): continue
    let value = result[field.name]
    case field.kind
    of vkBool:
      let b = boolArg(value)
      if b.isSome: result[field.name] = %b.get
    of vkInt:
      if value.kind == JString:
        try: result[field.name] = %parseBiggestInt(value.getStr)
        except ValueError: discard
    else: discard

proc unitArguments*(request: ServiceRequest; operation: string): JsonNode =
  ## §14.4: the client's arguments, with the mapping's arguments where the
  ## client gave none. The legacy `now` string still means `now`.
  result = if request.args.isNil: newJObject() else: request.args.copy
  case request.action
  of "kill":
    if not result.hasKey("signal"): result["signal"] = %"SIGTERM"
  of "enable", "disable":
    if not result.hasKey("now"):
      result["now"] = %(request.now.isSome and request.now.get.toLowerAscii == "true")
  of "stop":
    if operation == "mount.stop" and not result.hasKey("lazy"): result["lazy"] = %false
  else: discard
  result = coerceArguments(operation, result)

proc trackCall*(job: Job; call: Call) =
  if not call.isNil and call.state != clDone: job.calls.add call

proc dispatchUnit*(d: Daemon; job: Job; core, name, subsystem: string;
                  warnings: seq[string]) =
  let request = job.request.service
  var mapping: OperationMapping
  try: mapping = mapOperation(subsystem, request.action)
  except CoreError as e:
    d.respond(job, errorResponse(e.code, e.msg, core))
    return
  let args = unitArguments(request, mapping.operation)
  let streaming = request.action == "log-follow"
  let ctx = job.ctx
  let onEntry = if streaming: (proc(entry: JsonNode) =
      discard ctx.emit(entryControlEvent(entry))) else: nil
  let call = d.startCall(core, mapping.operation, name, args, internal = false,
    proc(r: CallResult) =
      var response = r.toResponse(core, warnings)
      d.respond(job, response),
    onEntry)
  job.trackCall(call)

proc resolveNative*(d: Daemon; name: string): ResolveReply =
  try: d.config.native.resolve(name)
  except CoreError as e: failedReply(e.code, e.msg)
  except CatchableError as e: failedReply(uncodedErrorCode(e), e.msg)

proc replyFrom*(r: CallResult; requested: string): ResolveReply =
  if not r.ok: return failedReply(r.code, r.message)
  let value = r.value
  if value.isNil or not value.hasKey("owned") or value["owned"].kind != JBool:
    return failedReply(ecProtocol, "unit.resolve omitted boolean owned")
  if not value["owned"].getBool: return answered(false)
  answered(true, value{"name"}.getStr(requested), value{"subsystem"}.getStr)

proc startResolve*(d: Daemon; core, name: string;
                  onReply: proc(reply: ResolveReply) {.closure.}): Call =
  ## `unit.resolve` on one core; the native one answers synchronously with
  ## its internal legacy-suffix hint.
  if core.isNative:
    let reply = d.resolveNative(name)
    if reply.kind == rrAnswered and reply.owned:
      d.indexOwned(core, name, reply.canonicalName)
    onReply(reply)
    return nil
  d.startCall(core, "unit.resolve", "", %*{"name": name}, internal = false,
    proc(r: CallResult) =
      let reply = replyFrom(r, name)
      if reply.kind == rrAnswered and reply.owned and validUnitName(reply.canonicalName):
        d.indexOwned(core, name, reply.canonicalName)
      onReply(reply))

proc refreshEnabled*(d: Daemon) =
  ## §9, §14.3: routing uses the effective enabled set, which is the state
  ## directory's content: `jumpctl cores enable/disable` change it while the
  ## daemon runs. The fixed E_STATE rule of §20.2 step 4 stays fixed.
  if d.stateError.isSome: return
  try:
    d.enabled = readEnabledState(d.config.statePaths).enabled
    d.enabledReadError = ""
  except CatchableError as e:
    if e.msg != d.enabledReadError:
      d.enabledReadError = e.msg
      d.log(clWarn, "", "enabled state not re-read; keeping the previous set: " & e.msg)

proc routeState*(d: Daemon; core: CoreRuntime): CoreRouteState =
  result = CoreRouteState(name: core.name, enabled: core.name in d.enabled,
    state: CoreRuntimeState(ord(core.state)), nameIndex: initNameIndex())
  if nameidx.hasIndex(d.nameIndexes, core.name):
    result.nameIndex = routing.nameIndex(nameidx.indexedNames(d.nameIndexes, core.name))

proc claims*(d: Daemon; core: string): bool =
  d.info.hasKey(core) and d.info[core].claimsUnit and not d.info[core].closed

proc stepService*(d: Daemon; job: Job)

proc queuedBehind*(d: Daemon; job: Job; core, caller: string): bool =
  ## A request from a loading core's `init` for a core still queued behind it
  ## would wait for a load that cannot start before the caller finishes:
  ## answer with the error for the core's state instead (§14.3, §20.1).
  caller.len > 0 and caller != core and d.stateOf(core) != csLoading and
    core in d.startupPending

proc respondQueued*(d: Daemon; job: Job; core, caller: string) =
  d.respond(job, errorResponse(ecCoreUnloaded, core & " has not started loading: " &
    "it is queued behind " & caller & ", whose init made this request", core))

proc stepServiceQualified*(d: Daemon; job: Job; core, unit: string) =
  let caller = d.callerLoadingCore(job)
  if d.coreLoading(core):
    if caller == core:
      d.respond(job, errorResponse(ecCoreState, "a loading core cannot route to itself", core))
      return
    if d.queuedBehind(job, core, caller):
      d.respondQueued(job, core, caller)
      return
    d.park(job, core, proc() = d.stepService(job))
    return
  let p = d.pos(core)
  if p < 0:
    d.respond(job, errorResponse(ecNotFound, "core not found: " & core, core))
    return
  let ready = routingError(d.registry.cores[p])
  if not ready.ok:
    d.respond(job, errorResponse(ready.error.code, ready.error.message, core))
    return
  if d.info.hasKey(core) and d.info[core].closed:
    d.respond(job, errorResponse(ecCoreState, core & " is closed to new requests", core))
    return
  let call = d.startResolve(core, unit, proc(reply: ResolveReply) =
    if job.done: return
    case reply.kind
    of rrFailed:
      d.respond(job, errorResponse(reply.errorCode, reply.errorMessage, core))
    of rrNotCalled, rrAnswered:
      if not reply.owned:
        d.respond(job, errorResponse(ecNotFound, "unit not found: " & unit, core))
      elif not validUnitName(reply.canonicalName) or reply.subsystem.len == 0:
        d.respond(job, errorResponse(ecProtocol, "unit.resolve returned an invalid answer", core))
      else:
        d.dispatchUnit(job, core, reply.canonicalName, reply.subsystem, @[]))
  job.trackCall(call)

proc stepServiceUnqualified*(d: Daemon; job: Job; unit: string) =
  let caller = d.callerLoadingCore(job)
  if d.anyLoading(caller):
    d.park(job, "", proc() = d.stepService(job))
    return
  var participants: seq[string]
  for core in d.registry.cores:
    if core.state == csLoaded and core.name != caller and d.claims(core.name):
      participants.add core.name
  var replies = initTable[string, ResolveReply]()
  var pending = participants.len
  let reference = job.request.service.name
  proc decide() =
    if job.done: return
    d.refreshEnabled()
    var states: seq[CoreRouteState]
    for core in d.registry.cores:
      var rs = d.routeState(core)
      if core.state == csLoaded and not d.claims(core.name):
        continue                  # cores that do not claim `unit` do not take part
      if replies.hasKey(core.name): rs.reply = replies[core.name]
      if core.state == csLoading and core.name == caller: continue
      states.add rs
    try:
      let decision = resolveOwner(reference, states, callerLoadingCore = caller)
      var warnings: seq[string]
      for warning in decision.warnings:
        warnings.add warning.core & ": " & warning.message & " (" & errorName(warning.code) & ")"
      d.dispatchUnit(job, decision.core, decision.name, decision.subsystem, warnings)
    except CoreError as e:
      d.respondError(job, e)
  if pending == 0:
    decide()
    return
  # A helper proc gives every closure its own `name` (closures created in a
  # loop body share one environment).
  proc ask(name: string) =
    let call = d.startResolve(name, unit, proc(reply: ResolveReply) =
      replies[name] = reply
      dec pending
      if pending == 0: decide())
    job.trackCall(call)
  for core in participants: ask(core)

proc stepService*(d: Daemon; job: Job) =
  if job.done: return
  if nowMs() >= job.deadlineMs:
    d.respond(job, errorResponse(ecTimeout, "timed out waiting for cores to load"))
    return
  var unitRef: UnitRef
  try: unitRef = parseUnitRef(job.request.service.name)
  except ValueError as e:
    d.respond(job, errorResponse(ecName, e.msg))
    return
  try: discard commandFromString(job.request.service.action)
  except CoreError as e:
    d.respondError(job, e)
    return
  if unitRef.qualified: d.stepServiceQualified(job, unitRef.core, unitRef.unit)
  else: d.stepServiceUnqualified(job, unitRef.unit)

# --- global operations (`op`) and fan-out ------------------------------------

proc afterList*(d: Daemon; core: string; r: CallResult) =
  if r.ok: d.indexRefresh(core, unitNames(r.value))

proc refreshAfterUnitLoad*(d: Daemon; core: string) =
  ## §14.3: the index is refreshed after `unit.load` from a fresh list.
  discard d.startCall(core, "unit.list", "", newJObject(), internal = true,
    proc(r: CallResult) = d.afterList(core, r))

proc stepOp*(d: Daemon; job: Job)

proc stepOpSingle*(d: Daemon; job: Job; core: string) =
  let caller = d.callerLoadingCore(job)
  if d.coreLoading(core):
    if caller == core:
      d.respond(job, errorResponse(ecCoreState, "a loading core cannot route to itself", core))
      return
    if d.queuedBehind(job, core, caller):
      d.respondQueued(job, core, caller)
      return
    d.park(job, core, proc() = d.stepOp(job))
    return
  let op = job.request.op
  let ctx = job.ctx
  let streaming = op.name == "log.follow"
  let onEntry = if streaming: (proc(entry: JsonNode) =
      discard ctx.emit(entryControlEvent(entry))) else: nil
  let call = d.startCall(core, op.name, "", coerceArguments(op.name, op.args),
    internal = false,
    proc(r: CallResult) =
      if op.name == "unit.list": d.afterList(core, r)
      elif op.name == "unit.load" and r.ok: d.refreshAfterUnitLoad(core)
      d.respond(job, r.toResponse(core)),
    onEntry)
  job.trackCall(call)

proc supports*(d: Daemon; core, operation: string): bool =
  if not d.plans.hasKey(core): return false
  let plan = d.plans[core]
  plan.operations.hasKey(operation) and
    plan.operations[operation].backend.kind != dispatch.bkUnsupported

proc stepOpFanOut*(d: Daemon; job: Job) =
  ## `units list`/`units load`/`get-default` without `--core` (§21.3, §21.4):
  ## every loaded core that supports the operation, in load order.
  let caller = d.callerLoadingCore(job)
  if d.anyLoading(caller):
    d.park(job, "", proc() = d.stepOp(job))
    return
  let op = job.request.op
  var cores: seq[string]
  for core in d.loadOrder:
    if d.stateOf(core) == csLoaded and d.supports(core, op.name) and
        not (d.info.hasKey(core) and d.info[core].closed):
      cores.add core
  var results = initOrderedTable[string, CallResult]()
  for core in cores: results[core] = CallResult()
  var pending = cores.len
  proc assemble() =
    if job.done: return
    var warnings: seq[string]
    case op.name
    of "unit.list":
      var units = newJArray()
      for core, r in results:
        if r.ok:
          for item in r.value{"units"}.getElems:
            var row = item.copy
            if row.kind == JObject: row["core"] = %core
            units.add row
        else: warnings.add core & ": " & errorName(r.code) & ": " & r.message
      d.respond(job, okResponse(%*{"units": units}, warnings))
    of "target.get-default":
      var defaults = newJArray()
      for core, r in results:
        if r.ok: defaults.add %*{"core": core, "name": r.value{"name"}.getStr}
        else: warnings.add core & ": " & errorName(r.code) & ": " & r.message
      d.respond(job, okResponse(%*{"defaults": defaults}, warnings))
    of "unit.load":
      var total = 0
      var rows = newJArray()
      for core, r in results:
        if r.ok:
          let loaded = r.value{"loaded"}.getBiggestInt
          total += int(loaded)
          var row = %*{"core": core, "loaded": loaded}
          if r.value.hasKey("errors"): row["errors"] = r.value["errors"]
          rows.add row
        else: warnings.add core & ": " & errorName(r.code) & ": " & r.message
      d.respond(job, okResponse(%*{"loaded": total, "cores": rows}, warnings))
    else: discard
  if pending == 0:
    assemble()
    return
  proc ask(name: string) =
    let call = d.startCall(name, op.name, "", coerceArguments(op.name, op.args),
      internal = false,
      proc(r: CallResult) =
        results[name] = r
        if op.name == "unit.list": d.afterList(name, r)
        elif op.name == "unit.load" and r.ok: d.refreshAfterUnitLoad(name)
        dec pending
        if pending == 0: assemble())
    job.trackCall(call)
  for core in cores: ask(core)

proc stepOp*(d: Daemon; job: Job) =
  if job.done: return
  if nowMs() >= job.deadlineMs:
    d.respond(job, errorResponse(ecTimeout, "timed out waiting for cores to load"))
    return
  let op = job.request.op
  if op.core.len == 0:
    if op.name notin ["unit.list", "unit.load", "target.get-default"]:
      d.respond(job, errorResponse(ecUsage, op.name & " needs a core"))
      return
    d.stepOpFanOut(job)
  else:
    d.stepOpSingle(job, op.core)
