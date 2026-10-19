## The request entry point: a control request becomes a job.
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
import ./daemon_routing
import ./daemon_cores
import ./daemon_lifecycle
import ./daemon_jobs

# ---------------------------------------------------------------------------
# Request entry point

proc requestName*(request: ControlRequest): string =
  case request.kind
  of rkService: (if request.service.action == "status": "status" else: request.service.action)
  of rkCore: "cores " & request.core.action
  else: $request.kind

proc cancelJob*(d: Daemon; job: Job) =
  if job.done: return
  job.done = true
  job.parked = false
  for call in job.calls:
    if not call.isNil: d.cancelCall(call)

proc describe*(request: ControlRequest): string =
  case request.kind
  of rkService: request.service.action & " " & request.service.name
  of rkOp: "op " & request.op.name & (if request.op.core.len > 0: " on " & request.op.core else: "")
  of rkCore: "cores " & request.core.action & " " & request.core.name.get("")
  else: $request.kind

proc handleRequest*(d: Daemon; request: ControlRequest; ctx: RequestContext) =
  let job = Job(request: request, ctx: ctx, peer: ctx.peer,
    deadlineMs: nowMs() + d.config.requestWaitMs)
  d.log(clDebug, "", "request from pid " & $ctx.peer.pid & ": " & describe(request))
  let rt = d
  ctx.onCancel = proc() = rt.cancelJob(job)
  try:
    if d.shuttingDown and not d.shutdownState.requestAllowed(requestName(request)):
      d.respond(job, errorResponse(ecShutdown, "the daemon is shutting down"))
      return
    case request.kind
    of rkService: d.stepService(job)
    of rkOp: d.stepOp(job)
    of rkCore:
      case request.core.action
      of "status": d.respond(job, d.coresStatus(request.core.name.get("")))
      of "list-loaded": d.respond(job, d.coresLoaded())
      of "load", "unload", "reload": d.lifecycleJob(job)
      else: d.respond(job, errorResponse(ecUsage, "unknown core action: " & request.core.action))
    of rkSession: d.sessionJob(job)
    of rkPower: d.powerJob(job)
    of rkUsers: d.usersJob(job)
    of rkEnv: d.envJob(job)
  except CoreError as e: d.respondError(job, e)
  except CatchableError as e: d.respond(job, errorResponse(uncodedErrorCode(e), e.msg))
  except Defect as e: d.respond(job, errorResponse(ecBackend, "internal error: " & e.msg))
  # The peer's pidfd belongs to the transport, which closes it with the
  # connection however the request ends; a parked session request therefore
  # still has it when it resumes (§7.6 step 3).
