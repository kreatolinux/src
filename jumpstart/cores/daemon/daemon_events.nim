## Runtime events and completions: adapter and supervisor events, the
## filesystems-ready point (§20.2), and the completions of extension calls.
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

# ---------------------------------------------------------------------------
# Completions and runtime events

proc coreOfAdapter*(name: string): string =
  var rest = name
  if rest.startsWith(RuntimeRunnerName & "/"): rest = rest[RuntimeRunnerName.len + 1 .. ^1]
  let slash = rest.find('/')
  let hash = rest.find('#')
  var stop = rest.len
  if slash >= 0: stop = min(stop, slash)
  if hash >= 0: stop = min(stop, hash)
  rest[0 ..< stop]

proc markFilesystemsReady*(d: Daemon; reporter: string) =
  ## §20.2: reached once per boot; the report that reached it is logged.
  if d.filesystemsReady: return
  d.filesystemsReady = true
  d.log(clInfo, reporter, "filesystems are ready" &
    (if reporter.len > 0: " (reported by " & reporter & ")" else: ""))
  if not d.config.logger.isNil:
    try: discard d.config.logger.setFilesystemsReady()
    except CatchableError: discard
  d.resources.filesystemsReady(nowMs())
  for core in d.loadOrder: d.ensureStateDir(core)

proc checkFilesystemsDeadline*(d: Daemon) =
  ## §20.2: the bounded wait for the filesystems-ready point.
  if d.filesystemsReady or d.filesystemsDeadlineMs == 0 or
      nowMs() < d.filesystemsDeadlineMs: return
  d.filesystemsDeadlineMs = 0
  d.log(clWarn, "", "no core reported filesystems-ready and startup has not finished " &
    "within " & $((if d.config.filesystemsWaitMs > 0: d.config.filesystemsWaitMs
                   else: FilesystemsWaitMs) div 1000) &
    "s: assuming the filesystems are ready")
  d.markFilesystemsReady("")

proc degrade*(d: Daemon; core, reason: string) =
  let p = d.pos(core)
  if p >= 0 and d.registry.cores[p].state == csLoaded:
    discard d.registry.markDegraded(core, reason)
    d.log(clError, core, "degraded: " & reason)

proc handleRuntimeEvent*(d: Daemon; event: RuntimeEvent) =
  let core = coreOfAdapter(event.adapter)
  case event.kind
  of rekLog:
    let level = case event.level
      of "trace": clTrace
      of "debug": clDebug
      of "warn": clWarn
      of "error": clError
      else: clInfo
    if not d.config.logger.isNil:
      try: d.config.logger.log(level, coreSource(core) & "/request:" & event.requestId, event.text)
      except CatchableError: discard
  of rekStdout, rekStderr:
    if not d.config.logger.isNil:
      try:
        let persistent = not event.adapter.startsWith(RuntimeRunnerName) and
          d.driver.manager.persistent(event.adapter)
        d.config.logger.logProcessOutput(core, event.adapter, event.text,
          stderr = event.kind == rekStderr, longLivedKind = if persistent: "adapter" else: "")
      except CatchableError: discard
  of rekIoError: d.log(clWarn, core, event.adapter & ": " & event.text)
  of rekExit: d.log(clDebug, core, event.adapter & " exited")
  of rekAdapter:
    let action = event.action
    case action.kind
    of aaEvent:
      if action.message.kind == pmEventEntry and d.byRequest.hasKey(action.requestId) and
          not action.adapter.startsWith(RuntimeRunnerName):
        let call = d.calls.getOrDefault(d.byRequest[action.requestId])
        if not call.isNil and not call.onEntry.isNil:
          try:
            validateEntry(action.message.data)
            call.onEntry(action.message.data)
          except CatchableError: discard
    of aaFilesystemsReady: d.markFilesystemsReady(core)
    of aaDegraded: d.degrade(core, action.detail)
    of aaNotification: d.log(clDebug, core, "notification from " & action.adapter)
    of aaNotificationDropped: d.log(clWarn, core, "notifications dropped from " & action.adapter)
    of aaLog: d.log(clWarn, core, action.adapter & ": " & action.detail)
    else: discard

proc processCompletions*(d: Daemon) =
  for completion in d.driver.takeCompletions():
    try:
      if d.byRequest.hasKey(completion.requestId):
        let call = d.calls.getOrDefault(d.byRequest[completion.requestId])
        d.byRequest.del(completion.requestId)
        if call.isNil: continue
        if completion.ok: d.finishCall(call, okResult(completion.value))
        else: d.finishCall(call, errResult(completion.code, completion.detail))
      elif completion.requestId in d.syncWaiting:
        d.syncCompletions[completion.requestId] = completion
    except Exception as fault:
      d.loopFault("completion", fault)

proc waitRequest*(d: Daemon; requestId: string; deadlineMs: int64): Completion =
  ## Wait (nested) for a lifecycle request started on the backend.
  d.syncWaiting.incl requestId
  defer: d.syncWaiting.excl requestId
  let ok = d.waitUntil(proc(): bool = d.syncCompletions.hasKey(requestId),
    d.effectiveDeadline(deadlineMs))
  if not ok:
    d.backend.cancel(requestId, nowMs())
    discard d.waitUntil(proc(): bool = d.syncCompletions.hasKey(requestId),
      d.effectiveDeadline(nowMs() + CancelSettleMs))
  if d.syncCompletions.hasKey(requestId):
    result = d.syncCompletions[requestId]
    d.syncCompletions.del(requestId)
  else:
    result = Completion(requestId: requestId, ok: false, code: ecTimeout,
      detail: "lifecycle function did not finish in time")

proc pumpSupervisors*(d: Daemon) =
  var cores: seq[string]
  for core, item in d.info:
    if not item.supervisor.isNil: cores.add core
  for core in cores:
    let p = d.pos(core)
    if p < 0: continue
    let runtime = d.info[core].supervisor
    if runtime.isNil: continue
    let wasLoaded = d.registry.cores[p].state == csLoaded
    var events: seq[SupervisorRuntimeEvent]
    try: events = runtime.advanceSupervisor(d.registry.cores[p], nowMs())
    except CatchableError as e:
      d.log(clWarn, core, "supervisor: " & e.msg)
    for event in events:
      case event.kind
      of sreFilesystemsReady: d.markFilesystemsReady(core)
      of sreExited:
        if wasLoaded: d.log(clError, core, "supervisor exited: " & event.detail)
      of sreNotificationDropped: d.log(clWarn, core, "supervisor notifications dropped")
      else: discard
