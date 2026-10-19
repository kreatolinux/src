## Starting native services.
import std/[os, strutils, tables]
import ../../common/logging
import ../configParser
import jumpstartcore/[cgroups, errors]
import globalVariables, status

proc nativeFail*(code: CoreErrorCode; message: string) {.noreturn.} =
  raise newCoreError(code, message, "serviceHandler")

proc splitUnitName*(name: string): tuple[definition, sub: string] =
  ## `foo` -> (foo, main); `foo::bar` -> (foo, bar).
  if "::" in name:
    let parts = name.split("::", 1)
    (parts[0], parts[1])
  else:
    (name, "main")

proc findServiceConfig*(ctx: NativeContext; name: string): tuple[
    unit: UnitConfig, service: ServiceConfig] =
  ## Raises E_NOT_FOUND for a missing decfile or sub-unit.
  let (definition, sub) = splitUnitName(name)
  try:
    result.unit = parseUnit(ctx.configRoot, definition)
  except CatchableError as e:
    nativeFail(ecNotFound, "service " & name & " couldn't be loaded: " & e.msg)
  for svc in result.unit.services:
    if svc.name == sub:
      result.service = svc
      return
  if "::" notin name and result.unit.services.len == 1:
    result.service = result.unit.services[0]
    return
  nativeFail(ecNotFound, "service " & name & " not found in unit configuration")

proc prepareCgroup*(ctx: NativeContext; name: string): string =
  ## units/UNIT.unit under serviceHandler's cgroup (§15.1 rule 6), or "" when
  ## serviceHandler runs without cgroup v2.
  if ctx.cgroups.isNone: return ""
  try:
    ensureUnitCgroup(ctx.cgroups.get, unitCgroupName(name), ctx.cgroupSystem)
  except CatchableError as e:
    nativeFail(ecCgroup, "cannot create cgroup for " & name & ": " & e.msg)

proc startService*(ctx: NativeContext; serviceName: string) =
  ## Start a service (`foo` or `foo::bar`). Starting a running service is a
  ## success. Raises CoreError on failure.
  if ctx.isRunning(serviceName):
    info "Service " & serviceName & " is already running, not starting it again"
    return
  let (unit, serviceConfig) = ctx.findServiceConfig(serviceName)
  if serviceConfig.exec.len == 0:
    nativeFail(ecBackend, "service " & serviceName & " has no exec command")

  # A runtime directory without a live record is what an exited or stopped
  # service leaves behind; it never blocks a new start.
  let stateDir = ctx.serviceStateDir(serviceName)
  if dirExists(stateDir):
    try: removeDir(stateDir)
    except CatchableError as e:
      nativeFail(ecIo, "cannot reset runtime state of " & serviceName & ": " & e.msg)
  try: createDir(stateDir)
  except CatchableError as e:
    nativeFail(ecIo, "cannot create runtime state of " & serviceName & ": " & e.msg)
  ctx.clearServiceExit(serviceName)

  let cgroup = ctx.prepareCgroup(serviceName)
  if serviceConfig.execPre.len > 0:
    try:
      let pre = ctx.runToCompletion(serviceConfig.execPre,
        "serviceHandler:" & serviceName & ":pre", cgroup, ctx.execPreTimeoutMs)
      if shellExitCode(pre) != 0:
        warn "execPre of " & serviceName & " exited with code " & $shellExitCode(pre)
    except CatchableError as e:
      nativeFail(ecBackend, "execPre of " & serviceName & " failed: " & e.msg)

  let record = ServiceRecord(name: serviceName, terminal: serviceConfig.terminal,
    oneshot: unit.unitType == utOneshot, postCommand: serviceConfig.execPost,
    cgroup: cgroup, running: true)
  # Only explicitly interactive services inherit PID 1's terminal. Ordinary
  # daemons get their own session and cannot consume console input.
  try:
    writeFile(stateDir / "status", "running")
    record.pid = ctx.spawnUnitProcess(serviceConfig.exec, serviceConfig.terminal,
      cgroup, "serviceHandler:" & serviceName,
      proc(s: ChildStatus) = ctx.onServiceExit(record, s))
  except CatchableError as e:
    record.running = false
    try: removeDir(stateDir)
    except CatchableError: discard
    nativeFail(ecBackend, "service " & serviceName & " couldn't be started: " & e.msg)
  record.startSeq = ctx.nextSequence()
  ctx.services[serviceName] = record
  ok "Started " & serviceName
