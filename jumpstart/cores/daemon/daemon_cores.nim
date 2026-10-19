## Core listing: the `cores status` and `cores loaded` answers.
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

# --- cores status ------------------------------------------------------------

proc manifestPathOf*(d: Daemon; core: string): string =
  for found in d.discovered.cores:
    if found.name == core and found.path.len > 0: return found.path / "init.kg"

proc coreRow*(d: Daemon; name: string): JsonNode =
  let p = d.pos(name)
  let rt = if p >= 0: d.registry.cores[p] else: CoreRuntime(name: name)
  result = %*{"name": name, "state": stateName(rt.state)}
  if rt.state.isLoaded and not name.isNative:
    let path = d.manifestPathOf(name)
    var stale = false
    if path.len == 0 or not fileExists(path): stale = coreStale(rt, ManifestMetadata(), false)
    else:
      try: stale = coreStale(rt, manifestMetadata(path))
      except CatchableError: stale = true
    result["stale"] = %stale
  if rt.state == csFailed:
    var code = "E_INIT"
    var message = rt.failure
    let colon = rt.failure.find(": ")
    if colon > 0 and rt.failure.startsWith("E_"):
      code = rt.failure[0 ..< colon]
      message = rt.failure[colon + 2 .. ^1]
    result["error"] = %*{"code": code, "message": message}

proc coresStatus*(d: Daemon; only: string): ControlResponse =
  var rows = newJArray()
  var names: seq[string]
  for found in d.discovered.cores: names.add found.name
  for core in d.registry.cores:
    if core.name notin names: names.add core.name   # enabled but not discovered
  for name in names:
    if only.len == 0 or name == only: rows.add d.coreRow(name)
  if only.len > 0 and rows.len == 0:
    return errorResponse(ecNotFound, "core not found: " & only, only)
  var value = %*{"cores": rows}
  if d.stateError.isSome:
    value["state_error"] = %*{"code": errorName(d.stateError.get[0]),
      "message": d.stateError.get[1]}
  okResponse(value)

proc coresLoaded*(d: Daemon): ControlResponse =
  var rows = newJArray()
  for name in d.loadOrder:
    if d.stateOf(name).isLoaded: rows.add d.coreRow(name)
  okResponse(%*{"cores": rows})
