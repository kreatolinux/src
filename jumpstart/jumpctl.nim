## jumpctl: the command-line client of Jumpstart (jumpstart-cores §21).
##
## Command construction and every output format live in `cores/cli/cli.nim`; this
## module parses argv with nested cligen command groups (§21.1), talks to the
## daemon over the mode's control socket (§14.5), and performs the local
## commands, which never connect to the socket.
import std/[algorithm, exitprocs, json, net, options, os, posix, strutils]
import cligen
import commonImports
import cores/backends/backend_runtime,
  cores/cli/[cli, local_run],
  cores/daemon/control,
  cores/manifest/[discovery, manifest, modes],
  cores/sessions/lingerfs,
  cores/lifecycle/state
import jumpstartcore/[environment, errors, names]
import cores/manifest/builtin_manifest
from jumpstartcore/spawn import userIdentityFor

const jumpctlLibDir {.strdefine: "jumpstartLibDir".} = "/usr/lib"
  ## build.sh passes -d:jumpstartLibDir; the runner is
  ## $LIBDIR/jumpstart/kongue-runner (§16.1).

type
  Context = object
    paths: CorePaths
    trustedUid: Uid    ## owner of the user core root and of enabled state
    systemOwner: Uid   ## owner of the system core root (§8.3: root)
    lingerOwner: int   ## owner of linger markers (§21.8: root)
    runnerPath: string
    runnerOwner: Uid

var followingLogs = false
var interruptText = ""

# ---------------------------------------------------------------------------
# Diagnostics (§18) and usage errors from cligen

proc fail(code: CoreErrorCode; message: string; core = "") {.noreturn.} =
  stderr.writeLine(diagnostic(code, message, core))
  quit(exitCode(code))
proc fail(e: ref CoreError; core = "") {.noreturn.} =
  fail(e.code, e.msg, if e.core.len > 0: e.core else: core)

var usageCapture: tuple[active: bool; saved, file: cint]

proc beginUsageCapture() =
  ## cligen writes its own parse errors to standard error. They are captured
  ## until a command starts and, if parsing fails, reported as `E_USAGE`
  ## diagnostics (§18) when cligen exits with status 2.
  var name = getTempDir() / "jumpctl-usage-XXXXXX"
  let fd = mkstemp(name.cstring)
  if fd < 0: return
  discard unlink(name.cstring)
  flushFile(stderr)
  let saved = dup(2)
  if saved < 0 or dup2(fd, 2) < 0:
    discard posix.close(fd)
    if saved >= 0: discard posix.close(saved)
    return
  usageCapture = (true, saved, fd)

proc endUsageCapture(): string =
  if not usageCapture.active: return ""
  usageCapture.active = false
  flushFile(stderr)
  discard dup2(usageCapture.saved, 2)
  discard posix.close(usageCapture.saved)
  discard lseek(usageCapture.file, 0, SEEK_SET)
  var buffer: array[4096, char]
  while true:
    let count = posix.read(usageCapture.file, addr buffer[0], buffer.len)
    if count <= 0: break
    for i in 0 ..< int(count): result.add buffer[i]
  discard posix.close(usageCapture.file)

proc reportUsageCapture() =
  let text = endUsageCapture()
  var parts: seq[string]
  for line in text.splitLines:
    let clean = line.strip
    if clean.len > 0: parts.add clean
  if parts.len > 0: stderr.writeLine(diagnostic(ecUsage, parts.join(" ")))

proc started() =
  ## First call of every command: argv parsing succeeded.
  let early = endUsageCapture()
  if early.len > 0: stderr.write early

# ---------------------------------------------------------------------------
# Context: mode, paths, and trusted owners (§7.1, §7.2)

proc realUid(): int = int(posix.getuid())

proc newContext(): Context =
  when defined(jumpctlTestHooks):
    # Test builds only: every path lives under JUMPCTL_TEST_ROOT and files are
    # owned by the test user. Production builds have no such inputs (§7.1).
    let root = getEnv("JUMPCTL_TEST_ROOT")
    let roots = CorePathRoots(systemCoreRoot: root / "lib/cores",
      systemConfigRoot: root / "etc", systemStateRoot: root / "var",
      systemRuntimeRoot: root / "run", systemCgroupRoot: root / "cgroup",
      systemLogPath: root / "log", systemSocketPath: root / "jumpstart.sock",
      lingerRoot: root / "etc/users/linger", userCoreRelative: "cores",
      userConfigRelative: "config", userStateRelative: "state",
      userDataRelative: "data", fallbackRuntimeRelative: "runtime",
      userCgroupRoot: root / "cgroup/users")
    let me = Uid(posix.getuid())
    # User-mode paths need a non-root uid; a root test run borrows one.
    let userUid = if me == Uid(0): 65534 else: int(me)
    result.paths = if getEnv("JUMPCTL_TEST_MODE") == "system": pathsFor(cmSystem, 0, roots = roots)
                   else: pathsFor(cmUser, userUid, root / "home", roots = roots)
    result.trustedUid = me
    result.systemOwner = me
    result.lingerOwner = int(me)
    result.runnerPath = getEnv("JUMPCTL_TEST_RUNNER")
    result.runnerOwner = me
  else:
    let uid = realUid()
    try: result.paths = pathsForPasswd(clientMode(uid), uid)
    except CatchableError as e: fail(ecIo, e.msg)
    result.trustedUid = Uid(uid)
    result.systemOwner = Uid(0)
    result.lingerOwner = 0
    result.runnerPath = jumpctlLibDir / "jumpstart" / "kongue-runner"
    result.runnerOwner = Uid(0)

proc manifestOwner(ctx: Context): int =
  ## §8.3: the trusted owner of manifests besides root. System roots belong to
  ## root, the user root to the user.
  int(if ctx.paths.mode == cmSystem: ctx.systemOwner else: ctx.trustedUid)

proc requireMode(ctx: Context; kind: CliCommandKind) =
  try: command(kind).validateMode(ctx.paths.mode)
  except CoreError as e: fail(e)

# ---------------------------------------------------------------------------
# Control socket client (§14.5)

var activeSocket: Socket

proc onInterrupt() {.noconv.} =
  ## §21.5, §14.5: an interrupt closes the connection, which cancels the
  ## request. `logs follow` ends normally; anything else reports E_CANCELLED.
  if followingLogs: exitnow(0)
  if interruptText.len > 0:
    discard posix.write(2, interruptText.cstring, interruptText.len)
  exitnow(cint(exitCode(ecCancelled)))

proc exchange(ctx: Context; request: ControlRequest;
              onEntry: proc(entry: JsonNode) = nil): (Reply, ReplyCollector) =
  ## Send one request and read `event` lines until its response. There is no
  ## client-side timeout: each operation is bounded by its own timeout.
  var collector = ReplyCollector()
  var sock: Socket
  try:
    sock = newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM, Protocol.IPPROTO_IP)
    sock.connectUnix(ctx.paths.socketPath)
  except CatchableError:
    if not sock.isNil: sock.close()
    fail(ecIo, "daemon not running")
  activeSocket = sock
  try:
    try: sock.send(serializeControlRequest(request))
    except CoreError as e: fail(e)
    except CatchableError as e: fail(ecIo, "cannot send request: " & e.msg)
    while true:
      var text: string
      try: text = sock.recvLine(maxLength = MaxControlLineBytes + 2)
      except CatchableError as e: fail(ecIo, "cannot read response: " & e.msg)
      if text.len == 0: fail(ecIo, "daemon closed the connection before responding")
      if text == "\c\L": continue
      let parsed = try: parseStreamLine(text)
                   except CoreError as e: fail(e)
      case parsed.kind
      of skEntry:
        if onEntry.isNil: fail(ecProtocol, "unexpected entry event")
        onEntry(parsed.entry)
      of skItem: collector.add parsed
      of skResponse: return (parsed.reply, collector)
  finally:
    activeSocket = nil
    sock.close()

proc emit(output: CliOutput) =
  if output.stdout.len > 0: stdout.write output.stdout
  if output.stderr.len > 0: stderr.write output.stderr
  flushFile(stdout)

proc transact(ctx: Context; cmd: CliCommand) =
  ## A command that sends exactly one request.
  ctx.requireMode(cmd.kind)
  let request = try: cmd.buildRequest(jumpstartVersion)
                except CoreError as e: fail(e)
  let (reply, collector) = ctx.exchange(request)
  let output = formatReply(cmd, reply, collector)
  emit output
  quit(output.exitStatus)

proc fanOut(ctx: Context; cmd: CliCommand) =
  ## §21.3, §21.4: without --core, ask every loaded core in load order and
  ## skip the cores that do not support the operation.
  if cmd.core.len > 0: ctx.transact(cmd)
  ctx.requireMode(cmd.kind)
  let (listed, listedItems) = ctx.exchange(command(ccCoresListLoaded).buildRequest(jumpstartVersion))
  if not listed.ok: fail(listed.code, listed.message, listed.core)
  let names = try: loadedCoreNames(listedItems.merged(listed))
              except CoreError as e: fail(e)
  var status = 0
  for core in names:
    var each = cmd
    each.core = core
    let request = try: each.buildRequest(jumpstartVersion)
                  except CoreError as e: fail(e)
    let (reply, collector) = ctx.exchange(request)
    if not reply.ok and reply.code == ecUnsupported: continue
    let output = formatReply(each, reply, collector)
    emit output
    if status == 0: status = output.exitStatus
  quit(status)

# ---------------------------------------------------------------------------
# Local state (§8, §9)

proc inspector(ctx: Context): ManifestInspector =
  let mode = ctx.paths.mode
  let owner = ctx.manifestOwner
  result = proc(path: string): ManifestInfo =
    let m = loadManifest(path, extractFilename(parentDir(path)), jumpstartVersion,
      trustedOwner = owner)
    result = ManifestInfo(name: m.name, modes: m.modes, referencedPaths: m.referencedPaths)
    if mode in m.modes:
      for op in m.resolveOps(mode):
        if op.backend == bkDelegate and op.delegateCore notin result.delegationTargets:
          result.delegationTargets.add op.delegateCore

proc discover(ctx: Context): DiscoveryResult =
  var roots: seq[CoreRoot]
  for i, root in ctx.paths.coreRoots:
    roots.add CoreRoot(path: root, trustedUid: ctx.trustedUid,
                       isUserRoot: ctx.paths.mode == cmUser and i > 0)
  try: discoverCores(ctx.paths.mode, roots, inspector(ctx),
                     DiscoveryOptions(systemOwner: ctx.systemOwner))
  except CoreError as e: fail(e)
  except CatchableError as e: fail(ecIo, e.msg)

proc statePaths(ctx: Context): StatePaths =
  StatePaths(enabledDir: ctx.paths.enabledRoot, lockFile: ctx.paths.stateLock,
             trustedUid: ctx.trustedUid)

proc enabledNames(ctx: Context): seq[string] =
  try: readEnabledState(ctx.statePaths).enabled
  except CoreError as e: fail(e)
  except CatchableError as e: fail(ecIo, e.msg)

proc findCore(found: DiscoveryResult; name: string): DiscoveredCore =
  ## The discovered, valid core `name`, or the error that rejected it.
  for core in found.cores:
    if core.name == name: return core
  for rejected in found.rejected:
    if rejected.name == name: fail(coreErrorCode(rejected.code), rejected.reason, name)
  fail(ecNotFound, "core not found: " & name, name)

proc daemonUser(ctx: Context): string =
  ## User mode: every operation runs as the daemon's user (§7.4, §21.11).
  if ctx.paths.mode == cmSystem: return ""
  let entry = getpwuid(Uid(realUid()))
  if entry.isNil: fail(ecPermission, "no password database entry for uid " & $realUid())
  $entry.pwName

proc requireCoreName(name: string) =
  if name != "serviceHandler" and not validCoreName(name):
    fail(ecName, "invalid or reserved core name: " & name, name)

proc one(values: seq[string]; what: string): string =
  if values.len != 1: fail(ecUsage, "expected exactly one " & what)
  values[0]

# ---------------------------------------------------------------------------
# Unit commands (§21.2, §21.3)

proc unitCommand(kind: CliCommandKind; unit: seq[string]; now = false;
                 target = ""; signal = "") =
  started()
  let ctx = newContext()
  var cmd = command(kind)
  cmd.unit = one(unit, "UNIT")
  cmd.now = now; cmd.target = target; cmd.signal = signal
  if kind == ccKill and signal.len == 0: fail(ecUsage, "--signal requires a signal")
  ctx.transact(cmd)

proc cmdStart(unit: seq[string]) =
  ## Start UNIT.
  unitCommand(ccStart, unit)
proc cmdStop(unit: seq[string]) =
  ## Stop UNIT.
  unitCommand(ccStop, unit)
proc cmdRestart(unit: seq[string]) =
  ## Restart UNIT (service.restart).
  unitCommand(ccRestart, unit)
proc cmdReload(unit: seq[string]) =
  ## Ask UNIT to reload its configuration (service.reload).
  unitCommand(ccReload, unit)
proc cmdKill(unit: seq[string]; signal = "SIGTERM") =
  ## Send a signal to the processes of UNIT (service.kill).
  unitCommand(ccKill, unit, signal = signal)
proc cmdEnable(unit: seq[string]; now = false; target = "") =
  ## Enable UNIT, into TARGET (a target of the same core) if given.
  unitCommand(ccEnable, unit, now, target)
proc cmdDisable(unit: seq[string]; now = false; target = "") =
  ## Disable UNIT, from TARGET (a target of the same core) if given.
  unitCommand(ccDisable, unit, now, target)
proc cmdStatus(unit: seq[string]) =
  ## Report the state of UNIT.
  unitCommand(ccStatus, unit)
proc cmdIsolate(unit: seq[string]) =
  ## Switch to the target UNIT (target.isolate).
  unitCommand(ccIsolate, unit)
proc cmdSetDefault(unit: seq[string]) =
  ## Make the target UNIT its core's default target.
  unitCommand(ccSetDefault, unit)
proc cmdGetDefault(core = "") =
  ## Print CORE/NAME, the default target of each loaded core.
  started()
  var cmd = command(ccGetDefault); cmd.core = core
  newContext().fanOut(cmd)

# ---------------------------------------------------------------------------
# units (§21.4)

proc cmdUnitsList(core = ""; subsystem = "") =
  ## List units as CORE/UNIT SUBSYSTEM ENABLEMENT.
  started()
  var cmd = command(ccUnitsList); cmd.core = core
  if subsystem.len > 0: cmd.args = %*{"subsystem": subsystem}
  newContext().fanOut(cmd)
proc cmdUnitsLoad(core = "") =
  ## Reread unit definitions (unit.load) and print CORE: loaded N.
  started()
  var cmd = command(ccUnitsLoad); cmd.core = core
  newContext().fanOut(cmd)
proc cmdUnitsValidate(unit: seq[string]) =
  ## Check one unit definition and print its diagnostics.
  started()
  var cmd = command(ccUnitsValidate); cmd.unit = one(unit, "UNIT")
  newContext().transact(cmd)
proc cmdUnitsTranslate(unit: seq[string]) =
  ## Print an equivalent native decfile for UNIT. Never writes files.
  started()
  var cmd = command(ccUnitsTranslate); cmd.unit = one(unit, "UNIT")
  newContext().transact(cmd)

# ---------------------------------------------------------------------------
# logs (§21.5)

proc optionalUnit(unit: seq[string]): string =
  if unit.len > 1: fail(ecUsage, "expected at most one UNIT")
  if unit.len == 1: unit[0] else: ""

proc cmdLogsRead(unit: seq[string]; core = ""; since = ""; until = "";
                 lines = DefaultLogLines) =
  ## Print log entries as TIME LEVEL UNIT MESSAGE.
  started()
  var cmd = command(ccLogsRead)
  cmd.unit = optionalUnit(unit); cmd.core = core
  cmd.since = since; cmd.until = until; cmd.lines = lines
  newContext().transact(cmd)

proc cmdLogsFollow(unit: seq[string]; core = ""; since = "") =
  ## Print log entries as they arrive, until interrupted.
  started()
  let ctx = newContext()
  var cmd = command(ccLogsFollow)
  cmd.unit = optionalUnit(unit); cmd.core = core; cmd.since = since
  let request = try: cmd.buildRequest(jumpstartVersion)
                except CoreError as e: fail(e)
  let owner = corePart(cmd.unit)
  followingLogs = true
  let (reply, collector) = ctx.exchange(request, proc(entry: JsonNode) =
    let text = try: formatLogEntry(entry, if owner.len > 0: owner else: core)
               except CoreError as e: fail(e)
    stdout.write text
    flushFile(stdout))
  followingLogs = false
  let output = formatReply(cmd, reply, collector)
  emit output
  quit(output.exitStatus)

proc cmdLogsWrite(args: seq[string]; core = ""; level = "") =
  ## Append an entry: logs write [UNIT] --level LEVEL MESSAGE.
  started()
  var cmd = command(ccLogsWrite)
  cmd.core = core; cmd.level = level
  case args.len
  of 1: cmd.message = args[0]
  of 2: cmd.unit = args[0]; cmd.message = args[1]
  else: fail(ecUsage, "expected [UNIT] MESSAGE")
  newContext().transact(cmd)

proc cmdLogsRotate(core = "") =
  ## Rotate the log storage of CORE.
  started()
  var cmd = command(ccLogsRotate); cmd.core = core
  if core.len == 0: fail(ecUsage, "--core is required")
  newContext().transact(cmd)

proc cmdLogsVacuum(core = ""; max_size = ""; max_age = "") =
  ## Delete old log entries of CORE.
  started()
  var cmd = command(ccLogsVacuum); cmd.core = core
  if core.len == 0: fail(ecUsage, "--core is required")
  if max_size.len > 0:
    try:
      let value = parseBiggestInt(max_size)
      if value < 0 or not max_size.allCharsInSet({'0'..'9'}): raise newException(ValueError, "")
      cmd.maxSize = some(int64(value))
    except ValueError: fail(ecUsage, "--max-size must be a number of bytes")
  if max_age.len > 0: cmd.maxAge = some(max_age)
  newContext().transact(cmd)

# ---------------------------------------------------------------------------
# Power (§21.6)

proc cmdPoweroff() =
  ## Power the system off.
  started(); newContext().transact(command(ccPoweroff))
proc cmdReboot() =
  ## Reboot the system.
  started(); newContext().transact(command(ccReboot))
proc cmdHalt() =
  ## Halt the system.
  started(); newContext().transact(command(ccHalt))

# ---------------------------------------------------------------------------
# users (§21.8)

proc cmdUsersList() =
  ## List user daemons as UID USER SESSIONS STATE LINGER.
  started(); newContext().transact(command(ccUsersList))

proc lingerContext(kind: CliCommandKind): Context =
  result = newContext()
  result.requireMode(kind)
  try: requireLinger(result.paths)
  except ModeError as e: fail(ecUsage, e.msg)

proc cmdLingerList() =
  ## List lingering users, one per line.
  started()
  let ctx = lingerContext(ccUsersLingerList)
  var names = try: listLingerNames(ctx.paths.lingerRoot, ctx.lingerOwner)
              except CatchableError as e: fail(ecIo, e.msg)
  names.sort(system.cmp[string])
  for name in names: echo name

proc lingerChange(user: seq[string]; enabling: bool) =
  started()
  let ctx = lingerContext(if enabling: ccUsersLingerEnable else: ccUsersLingerDisable)
  let name = one(user, "USER")
  let entry = getpwnam(name.cstring)
  if entry.isNil: fail(ecNotFound, "no such user: " & name)
  if name == "root" or entry.pwUid == Uid(0): fail(ecUsage, "root cannot linger")
  if not validLingerName(name): fail(ecUsage, "invalid user name: " & name)
  try:
    if enabling: createLingerMarker(ctx.paths.lingerRoot, name, ctx.lingerOwner)
    else: removeLingerMarker(ctx.paths.lingerRoot, name)
  except CatchableError as e: fail(ecIo, e.msg)
  echo "jumpctl: ", (if enabling: "enabled" else: "disabled"), " linger for ", name

proc cmdLingerEnable(user: seq[string]) =
  ## Start USER's daemon at boot (creates the linger marker).
  lingerChange(user, true)
proc cmdLingerDisable(user: seq[string]) =
  ## Stop lingering for USER (removes the linger marker).
  lingerChange(user, false)

# ---------------------------------------------------------------------------
# env (§21.9)

proc cmdEnvList() =
  ## Print the user environment store as KEY=VALUE lines.
  started(); newContext().transact(command(ccEnvList))
proc cmdEnvSet(assignments: seq[string]) =
  ## Set variables: env set KEY=VALUE...
  started()
  var cmd = command(ccEnvSet); cmd.values = assignments
  newContext().transact(cmd)
proc cmdEnvUnset(keys: seq[string]) =
  ## Remove variables: env unset KEY...
  started()
  var cmd = command(ccEnvUnset); cmd.keys = keys
  newContext().transact(cmd)
proc cmdEnvImport(keys: seq[string]) =
  ## Copy variables from jumpctl's own environment: env import KEY...
  started()
  let ctx = newContext()
  ctx.requireMode(ccEnvImport)
  if keys.len == 0: fail(ecUsage, "at least one KEY is required")
  var cmd = command(ccEnvImport)
  for key in keys:
    try: validateEnvKey(key)
    except CoreError as e: fail(e)
  for key in keys:
    if existsEnv(key): cmd.values.add key & "=" & getEnv(key)
    else: stderr.writeLine("jumpctl: warning: " & key & " is not set; skipped")
  if cmd.values.len == 0: quit(0)
  ctx.transact(cmd)

# ---------------------------------------------------------------------------
# cores (§21.10 - §21.15)

proc cmdCoresList(enabled = false; loaded = false) =
  ## List discovered cores, one per line.
  started()
  let ctx = newContext()
  if enabled and loaded: fail(ecUsage, "--enabled and --loaded are mutually exclusive")
  if loaded:
    var cmd = command(ccCoresList); cmd.loadedOnly = true
    ctx.transact(cmd)
  let found = ctx.discover()
  let only = if enabled: ctx.enabledNames() else: @[]
  for core in found.cores:
    if not enabled or core.name in only: echo core.name

proc cmdCoresStatus(core: seq[string]) =
  ## Print CORE STATE for each discovered core.
  started()
  var cmd = command(ccCoresStatus)
  if core.len > 1: fail(ecUsage, "expected at most one CORE")
  if core.len == 1: cmd.core = core[0]
  newContext().transact(cmd)

proc liveCore(kind: CliCommandKind; core: seq[string]; stop_units: bool) =
  started()
  var cmd = command(kind)
  cmd.core = one(core, "CORE"); cmd.stopUnits = stop_units
  newContext().transact(cmd)

proc cmdCoresLoad(core: seq[string]) =
  ## Load CORE into the running daemon until it restarts.
  liveCore(ccCoresLoad, core, false)
proc cmdCoresUnload(core: seq[string]; stop_units = false) =
  ## Unload CORE from the running daemon.
  liveCore(ccCoresUnload, core, stop_units)
proc cmdCoresReload(core: seq[string]; stop_units = false) =
  ## Reload CORE in the running daemon.
  liveCore(ccCoresReload, core, stop_units)

proc persistCore(ctx: Context; name: string; enabling: bool) =
  let found = ctx.discover()
  if enabling: enableCore(ctx.statePaths, name, found)
  else: disableCore(ctx.statePaths, name, found)

proc checkPersistCore(ctx: Context; name: string; enabling: bool) =
  let found = ctx.discover()
  if enabling: checkEnableCore(ctx.statePaths, name, found)
  else: checkDisableCore(ctx.statePaths, name, found)

proc coreChange(core: seq[string]; enabling, now, stopUnits: bool) =
  started()
  let ctx = newContext()
  let name = one(core, "CORE")
  if stopUnits and not now: fail(ecUsage, "--stop-units is valid only with --now")
  requireCoreName(name)
  let kind = if enabling: ccCoresEnable else: ccCoresDisable
  if now:
    # §21.14: the live change first; persist only if it succeeded. Failures
    # the persistent change can already be predicted to hit (E_DELEGATION, an
    # empty enabled set, an undiscovered core) fail here, before the live
    # step, so neither state changes.
    try: ctx.checkPersistCore(name, enabling)
    except CoreError as e: fail(e, name)
    except CatchableError as e: fail(ecIo, e.msg, name)
    var cmd = command(kind)
    cmd.core = name; cmd.now = true; cmd.stopUnits = stopUnits
    let (reply, _) = ctx.exchange(cmd.buildRequest(jumpstartVersion))
    if not reply.ok:
      fail(reply.code, reply.message, if reply.core.len > 0: reply.core else: name)
    emit CliOutput(stderr: formatWarnings(reply.warnings))
    try: ctx.persistCore(name, enabling)
    except CatchableError as e:
      let detail = if e of CoreError: errorName((ref CoreError)(e).code) & ": " & e.msg
                   else: e.msg
      fail(ecIo, "live and persistent states now differ: core " & name & " was " &
        (if enabling: "loaded, but enabling it" else: "unloaded, but disabling it") &
        " persistently failed: " & detail, name)
  else:
    try: ctx.persistCore(name, enabling)
    except CoreError as e: fail(e, name)
    except CatchableError as e: fail(ecIo, e.msg, name)
  echo "jumpctl: ", (if enabling: "enabled" else: "disabled"), " core ", name

proc cmdCoresEnable(core: seq[string]; now = false) =
  ## Enable CORE persistently; with --now, load it first.
  coreChange(core, true, now, false)
proc cmdCoresDisable(core: seq[string]; now = false; stop_units = false) =
  ## Disable CORE persistently; with --now, unload it first.
  coreChange(core, false, now, stop_units)

proc cmdCoresShow(core: seq[string]; resolved = false) =
  ## Print the manifest summary and operation table of CORE.
  started()
  let ctx = newContext()
  let name = one(core, "CORE")
  let found = ctx.discover()
  let enabled = if name in ctx.enabledNames(): "yes" else: "no"
  var lines: seq[string]
  try:
    if name == "serviceHandler":
      # §21.11: the virtual manifest of Appendix A.
      lines = formatShow(serviceHandlerManifest(jumpstartVersion), ctx.paths.mode,
        enabled, resolved, ctx.daemonUser())
    else:
      let path = found.findCore(name).path / "init.kg"
      lines = formatShow(loadManifest(path, name, jumpstartVersion,
        trustedOwner = ctx.manifestOwner), ctx.paths.mode,
        enabled, resolved, ctx.daemonUser())
  except CoreError as e: fail(e, name)
  except CatchableError as e: fail(ecIo, e.msg, name)
  for text in lines: echo text

proc cmdCoresCheck(core: seq[string]) =
  ## Validate every extension, or CORE; exit 1 on any error.
  started()
  let ctx = newContext()
  if core.len > 1: fail(ecUsage, "expected at most one CORE")
  let name = if core.len == 1: core[0] else: ""
  let found = ctx.discover()
  var matched = name.len == 0 or name == "serviceHandler"
  var errors = 0
  for rejected in found.rejected:
    if name.len > 0 and rejected.name != name: continue
    matched = true
    inc errors
    stderr.writeLine(diagnostic(coreErrorCode(rejected.code), rejected.reason, rejected.name))
  for discovered in found.cores:
    if discovered.name == "serviceHandler": continue
    if name.len > 0 and discovered.name != name: continue
    matched = true
    try:
      let m = loadManifest(discovered.path / "init.kg", discovered.name, jumpstartVersion,
        trustedOwner = ctx.manifestOwner)
      for warning in unreferencedFunctionWarnings(m):
        stderr.writeLine("jumpctl: " & discovered.name & ": warning: " & warning)
    except CoreError as e:
      inc errors
      stderr.writeLine(diagnostic(e.code, e.msg, discovered.name))
    except CatchableError as e:
      inc errors
      stderr.writeLine(diagnostic(ecIo, e.msg, discovered.name))
  if not matched: fail(ecNotFound, "core not found: " & name, name)
  quit(if errors > 0: 1 else: 0)

proc runtimeConfig(ctx: Context): RuntimeConfig =
  result = RuntimeConfig(mode: ctx.paths.mode, jumpstartVersion: runningVersionNumber(jumpstartVersion),
    runnerPath: ctx.runnerPath, runnerTrustedUid: ctx.runnerOwner,
    trustedUid: ctx.trustedUid, runtimeDir: ctx.paths.runtimeDir)
  if ctx.paths.mode == cmUser:
    result.identity = userIdentityFor(Uid(realUid()))
    result.canonicalRuntimeDir = ctx.paths.runtimeDir == canonicalRuntimeDirFor(realUid())

var runInterrupted = false

proc onRunInterrupt() {.noconv.} =
  ## §21.15: the first interrupt cancels the request (§13.7); a second one
  ## stops waiting for the cancellation.
  if runInterrupted:
    discard posix.write(2, interruptText.cstring, interruptText.len)
    exitnow(cint(exitCode(ecCancelled)))
  runInterrupted = true

proc cmdCoresRun(args: seq[string]) =
  ## Run one operation of CORE without the daemon: CORE OPERATION [UNIT] [KEY=VALUE...].
  started()
  let ctx = newContext()
  let request = try: parseRunArguments(args)
                except CoreError as e: fail(e)
  let found = ctx.discover()
  let loader = proc(name: string): LocalCore =
    for core in found.cores:
      if core.name != name: continue
      let m = try: loadManifest(core.path / "init.kg", name, jumpstartVersion,
                  trustedOwner = ctx.manifestOwner)
              except CoreError as e: raise e
              except CatchableError as e: raise newCoreError(ecManifest, e.msg, name)
      return LocalCore(manifest: m, dirs: CoreDirectories(root: core.path,
        stateDir: ctx.paths.stateRoot / name, runtimeDir: ctx.paths.runtimeRoot / name))
    for rejected in found.rejected:
      if rejected.name == name:
        raise newCoreError(coreErrorCode(rejected.code), rejected.reason, name)
    raise newCoreError(ecNotFound, "core not found: " & name, name)
  var hooks = LocalRunHooks()
  hooks.onItem = proc(operation, field: string; item: JsonNode) =
    stdout.write formatLocalItem(field, item)
    flushFile(stdout)
  hooks.onEntry = proc(entry: JsonNode) =
    stdout.write formatLocalItem("entries", entry)
    flushFile(stdout)
  hooks.onOutput = proc(core, text: string) = stderr.writeLine("core:" & core & ": " & text)
  hooks.interrupted = proc(): bool = runInterrupted
  setControlCHook(onRunInterrupt)
  var target = none(LocalTarget)
  try:
    let outcome = runLocal(loader, ctx.runtimeConfig, request.core, request.operation,
      request.unit, request.args, hooks,
      beforeRun = proc(resolved: LocalTarget) =
        target = some(resolved)
        if resolved.mutating: stderr.write mutatingWarning(request.operation))
    stdout.write formatLocalResult(outcome.operation, outcome.value, outcome.streamed)
  except CoreError as e:
    # A streaming operation such as log.follow ends by cancellation; like
    # `logs follow`, interrupting it is a normal end.
    if e.code == ecCancelled and runInterrupted and target.isSome and
        operationIsStreaming(target.get.operation): quit(0)
    fail(e, request.core)
  except CatchableError as e: fail(ecBackend, e.msg, request.core)

# ---------------------------------------------------------------------------
# Command tree (§21.1): nested cligen groups with --help at every level.

dispatchMultiGen(["linger", cmdName = "jumpctl users linger",
                  doc = "Manage lingering users (system mode, local).\n\n"],
  [cmdLingerList, cmdName = "list", dispatchName = "dLingerList",
   mergeNames = @["jumpctl", "users", "linger"]],
  [cmdLingerEnable, cmdName = "enable", dispatchName = "dLingerEnable",
   mergeNames = @["jumpctl", "users", "linger"], help = {"user": "USER"}],
  [cmdLingerDisable, cmdName = "disable", dispatchName = "dLingerDisable",
   mergeNames = @["jumpctl", "users", "linger"], help = {"user": "USER"}])

dispatchMultiGen(["users", cmdName = "jumpctl users",
                  doc = "Manage user daemons (system mode).\n\n"],
  [cmdUsersList, cmdName = "list", dispatchName = "dUsersList",
   mergeNames = @["jumpctl", "users"]],
  [linger, doc = "Manage lingering users (local).", dispatchName = "dLinger",
   mergeNames = @["jumpctl", "users"], stopWords = lingerSubCmds,
   suppress = @["usage", "prefix"], noHdr = true,
   usage = topLevelHelp("Manage lingering users (system mode, local).\n\n",
     "CG-TL" & clUseMulti, "jumpctl users linger", lingerSubCmds, lingerSubDocs)])

dispatchMultiGen(["units", cmdName = "jumpctl units", doc = "Inspect units.\n\n"],
  [cmdUnitsList, cmdName = "list", dispatchName = "dUnitsList",
   mergeNames = @["jumpctl", "units"],
   help = {"core": "only this core", "subsystem": "only this subsystem"}],
  [cmdUnitsLoad, cmdName = "load", dispatchName = "dUnitsLoad",
   mergeNames = @["jumpctl", "units"], help = {"core": "only this core"}],
  [cmdUnitsValidate, cmdName = "validate", dispatchName = "dUnitsValidate",
   mergeNames = @["jumpctl", "units"]],
  [cmdUnitsTranslate, cmdName = "translate", dispatchName = "dUnitsTranslate",
   mergeNames = @["jumpctl", "units"]])

dispatchMultiGen(["logs", cmdName = "jumpctl logs", doc = "Read and manage core logs.\n\n"],
  [cmdLogsRead, cmdName = "read", dispatchName = "dLogsRead",
   mergeNames = @["jumpctl", "logs"],
   help = {"core": "core, required without UNIT", "since": "RFC 3339 time",
           "until": "RFC 3339 time", "lines": "at most this many entries (1-10000)"}],
  [cmdLogsFollow, cmdName = "follow", dispatchName = "dLogsFollow",
   mergeNames = @["jumpctl", "logs"],
   help = {"core": "core, required without UNIT", "since": "RFC 3339 time"}],
  [cmdLogsWrite, cmdName = "write", dispatchName = "dLogsWrite",
   mergeNames = @["jumpctl", "logs"],
   help = {"core": "core, required without UNIT", "level": "debug, info, notice, warn, error, or fatal"}],
  [cmdLogsRotate, cmdName = "rotate", dispatchName = "dLogsRotate",
   mergeNames = @["jumpctl", "logs"], help = {"core": "core (required)"}],
  [cmdLogsVacuum, cmdName = "vacuum", dispatchName = "dLogsVacuum",
   mergeNames = @["jumpctl", "logs"],
   help = {"core": "core (required)", "max-size": "BYTES", "max-age": "DURATION"}])

dispatchMultiGen(["env", cmdName = "jumpctl env",
                  doc = "Manage the user environment store (user mode).\n\n"],
  [cmdEnvList, cmdName = "list", dispatchName = "dEnvList", mergeNames = @["jumpctl", "env"]],
  [cmdEnvSet, cmdName = "set", dispatchName = "dEnvSet", mergeNames = @["jumpctl", "env"]],
  [cmdEnvUnset, cmdName = "unset", dispatchName = "dEnvUnset", mergeNames = @["jumpctl", "env"]],
  [cmdEnvImport, cmdName = "import", dispatchName = "dEnvImport", mergeNames = @["jumpctl", "env"]])

dispatchMultiGen(["cores", cmdName = "jumpctl cores", doc = "Inspect and manage cores.\n\n"],
  [cmdCoresList, cmdName = "list", dispatchName = "dCoresList", mergeNames = @["jumpctl", "cores"],
   help = {"enabled": "only enabled cores (local)", "loaded": "only loaded cores (daemon)"}],
  [cmdCoresStatus, cmdName = "status", dispatchName = "dCoresStatus", mergeNames = @["jumpctl", "cores"]],
  [cmdCoresEnable, cmdName = "enable", dispatchName = "dCoresEnable", mergeNames = @["jumpctl", "cores"],
   help = {"now": "also load the core"}],
  [cmdCoresDisable, cmdName = "disable", dispatchName = "dCoresDisable", mergeNames = @["jumpctl", "cores"],
   help = {"now": "also unload the core", "stop-units": "stop its units (with --now)"}],
  [cmdCoresLoad, cmdName = "load", dispatchName = "dCoresLoad", mergeNames = @["jumpctl", "cores"]],
  [cmdCoresUnload, cmdName = "unload", dispatchName = "dCoresUnload", mergeNames = @["jumpctl", "cores"],
   help = {"stop-units": "stop the core's active units"}],
  [cmdCoresReload, cmdName = "reload", dispatchName = "dCoresReload", mergeNames = @["jumpctl", "cores"],
   help = {"stop-units": "stop the core's active units"}],
  [cmdCoresShow, cmdName = "show", dispatchName = "dCoresShow", mergeNames = @["jumpctl", "cores"],
   help = {"resolved": "print every option with its effective value"}],
  [cmdCoresCheck, cmdName = "check", dispatchName = "dCoresCheck", mergeNames = @["jumpctl", "cores"]],
  [cmdCoresRun, cmdName = "run", dispatchName = "dCoresRun", mergeNames = @["jumpctl", "cores"]])

when isMainModule:
  cgParseErrorExitCode = exitCode(ecUsage)  # §21.16: usage errors exit 2
  clCfg.version = jumpstartVersion
  beginUsageCapture()
  addExitProc(reportUsageCapture)
  interruptText = diagnostic(ecCancelled, "interrupted") & "\n"
  setControlCHook(onInterrupt)
  dispatchMulti(["multi", cmdName = "jumpctl",
    doc = "Control Jumpstart and its cores.\nA UNIT that begins with '-' is accepted only after '--', as in: jumpctl status -- -.mount\n\n"],
    [cmdStart, cmdName = "start", dispatchName = "dStart"],
    [cmdStop, cmdName = "stop", dispatchName = "dStop"],
    [cmdRestart, cmdName = "restart", dispatchName = "dRestart"],
    [cmdReload, cmdName = "reload", dispatchName = "dReload"],
    [cmdKill, cmdName = "kill", dispatchName = "dKill",
     help = {"signal": "signal name (HUP, SIGHUP) or number"}],
    [cmdEnable, cmdName = "enable", dispatchName = "dEnable",
     help = {"now": "also start the unit", "target": "target unit of the same core"}],
    [cmdDisable, cmdName = "disable", dispatchName = "dDisable",
     help = {"now": "also stop the unit", "target": "target unit of the same core"}],
    [cmdStatus, cmdName = "status", dispatchName = "dStatus"],
    [cmdIsolate, cmdName = "isolate", dispatchName = "dIsolate"],
    [cmdSetDefault, cmdName = "set-default", dispatchName = "dSetDefault"],
    [cmdGetDefault, cmdName = "get-default", dispatchName = "dGetDefault",
     help = {"core": "only this core"}],
    [units, doc = "Inspect units.", stopWords = unitsSubCmds, suppress = @["usage", "prefix"], noHdr = true,
     usage = topLevelHelp("Inspect units.\n\n", "CG-TL" & clUseMulti, "jumpctl units",
       unitsSubCmds, unitsSubDocs)],
    [logs, doc = "Read and manage core logs.", stopWords = logsSubCmds,
     suppress = @["usage", "prefix"], noHdr = true,
     usage = topLevelHelp("Read and manage core logs.\n\n", "CG-TL" & clUseMulti,
       "jumpctl logs", logsSubCmds, logsSubDocs)],
    [cmdPoweroff, cmdName = "poweroff", dispatchName = "dPoweroff"],
    [cmdReboot, cmdName = "reboot", dispatchName = "dReboot"],
    [cmdHalt, cmdName = "halt", dispatchName = "dHalt"],
    [users, doc = "Manage user daemons (system mode).", stopWords = usersSubCmds,
     suppress = @["usage", "prefix"], noHdr = true,
     usage = topLevelHelp("Manage user daemons (system mode).\n\n", "CG-TL" & clUseMulti,
       "jumpctl users", usersSubCmds, usersSubDocs)],
    [env, doc = "Manage the user environment store (user mode).", stopWords = envSubCmds,
     suppress = @["usage", "prefix"], noHdr = true,
     usage = topLevelHelp("Manage the user environment store (user mode).\n\n",
       "CG-TL" & clUseMulti, "jumpctl env", envSubCmds, envSubDocs)],
    [cores, doc = "Inspect and manage cores.", stopWords = coresSubCmds,
     suppress = @["usage", "prefix"], noHdr = true,
     usage = topLevelHelp("Inspect and manage cores.\n\n", "CG-TL" & clUseMulti,
       "jumpctl cores", coresSubCmds, coresSubDocs)])
