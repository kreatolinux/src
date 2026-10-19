## Runtime state of serviceHandler's native units.
##
## Every native operation receives a `NativeContext`. It holds the injected
## roots, the daemon's central reaper (§15.3), the optional per-unit cgroup
## layout (§15.1 rule 6), and the in-memory records of running services and
## timers. No process is waited for outside the reaper: exits arrive through
## reaper callbacks, and synchronous waits pump the reaper (`pump`).
##
## Unit processes are created by the spawn layer (jumpstartcore/spawn.nim): each is
## registered with the central reaper before it can exit (§15.3) and joins its
## unit cgroup before execve (§15.1 rules 6, 8).
import std/[cmdline, monotimes, options, os, posix, strutils, tables, times]
import jumpstartcore/[cgroups, reaper, spawn]

export options, reaper, spawn

type
  ServiceRecord* = ref object
    name*: string
    pid*: Pid
    terminal*: bool
    oneshot*: bool
    running*: bool            ## Main process has not exited yet.
    requestedStop*: bool      ## Jumpstart asked it to stop (§Appendix A).
    exitCode*: int            ## Shell-style exit code (128+N for signal N).
    exitStatus*: ChildStatus
    postCommand*: string
    postRunning*: bool
    cgroup*: string           ## units/UNIT.unit, "" without cgroups.
    startSeq*: int            ## Value of NativeContext.sequence at start.
    exitSeq*: int             ## Value of NativeContext.sequence at exit.

  TimerArgs* = object
    ## Copied into the timer thread. Threadvars such as `sockPath` are empty
    ## in new threads, so every path is passed explicitly.
    timerName*: string
    interval*: int
    serviceName*: string
    onMissed*: string
    stateDir*: string
    socketPath*: string
    clientVersion*: string
    stopFlag*: ptr bool

  TimerRecord* = object
    timerName*: string
    thread*: ptr Thread[TimerArgs]
    stopFlag*: ptr bool

  NativeContext* = ref object
    configRoot*: string       ## Mode's unit config directory (§7.2).
    runtimeRoot*: string      ## serviceHandler's runtime directory.
    socketPath*: string       ## Control socket, used by timer threads.
    reaper*: Reaper           ## The daemon's single central reaper.
    pump*: proc() {.closure.} ## Deliver pending exits; default drains `reaper`.
    environment*: seq[EnvPair]   ## Explicit environment of unit processes.
    workingDirectory*: string    ## Working directory of unit processes.
    cgroups*: Option[CoreCgroups] ## cores/serviceHandler/; none without v2.
    cgroupSystem*: CgroupSystem
    stopTimeoutMs*: int       ## SIGTERM grace before SIGKILL on stop.
    execPreTimeoutMs*: int    ## A service's execPre is killed after this long.
    services*: Table[string, ServiceRecord]
    lastExitRequested*: Table[string, bool]
    timers*: seq[TimerRecord]
    sequence*: int            ## Monotonic event counter (starts and exits).

const
  DefaultStopTimeoutMs* = 10_000 ## Historical native stop grace period.
  DefaultExecPreTimeoutMs* = 90_000 ## A hung execPre must not hold a unit's lock forever.

proc newNativeContext*(configRoot, runtimeRoot: string; reaper: Reaper;
                       socketPath = "";
                       environment: seq[EnvPair] = buildSystemEnvironment();
                       workingDirectory = "/";
                       cgroups = none(CoreCgroups);
                       cgroupSystem = defaultCgroupSystem();
                       stopTimeoutMs = DefaultStopTimeoutMs;
                       execPreTimeoutMs = DefaultExecPreTimeoutMs): NativeContext =
  if reaper.isNil: raise newException(ValueError, "a central reaper is required")
  result = NativeContext(configRoot: configRoot, runtimeRoot: runtimeRoot,
    socketPath: socketPath, reaper: reaper, environment: environment,
    workingDirectory: workingDirectory, cgroups: cgroups,
    cgroupSystem: cgroupSystem, stopTimeoutMs: stopTimeoutMs,
    execPreTimeoutMs: execPreTimeoutMs,
    services: initTable[string, ServiceRecord](),
    lastExitRequested: initTable[string, bool]())
  let r = reaper
  result.pump = proc() = discard r.drain()

proc nextSequence*(ctx: NativeContext): int =
  inc ctx.sequence
  ctx.sequence

proc serviceStateDir*(ctx: NativeContext, name: string): string =
  ctx.runtimeRoot / name

proc mountStateDir*(ctx: NativeContext, name: string): string =
  ctx.runtimeRoot / "mounts" / name

proc timerStateDir*(ctx: NativeContext, name: string): string =
  ctx.runtimeRoot / "timers" / name

proc recordServiceExit*(ctx: NativeContext, serviceName: string, requested: bool) =
  ## Whether the last exit of each service followed a requested stop is kept
  ## in memory (Appendix A status mapping).
  ctx.lastExitRequested[serviceName] = requested

proc lastServiceExitWasRequested*(ctx: NativeContext, serviceName: string): bool =
  ctx.lastExitRequested.getOrDefault(serviceName, false)

proc clearServiceExit*(ctx: NativeContext, serviceName: string) =
  ctx.lastExitRequested.del(serviceName)

proc findService*(ctx: NativeContext, serviceName: string): ServiceRecord =
  ## nil for a service this daemon never started.
  ctx.services.getOrDefault(serviceName, nil)

proc isRunning*(ctx: NativeContext, serviceName: string): bool =
  let record = ctx.findService(serviceName)
  not record.isNil and record.running

proc findTimerIndex*(ctx: NativeContext, timerName: string): int =
  for i in 0 ..< ctx.timers.len:
    if ctx.timers[i].timerName == timerName: return i
  -1

proc shellExitCode*(status: ChildStatus): int =
  ## The code the historical status files record: the exit status, or 128+N
  ## for a process killed by signal N (143 after SIGTERM).
  case status.kind
  of cekExited: status.code
  of cekSignaled: 128 + status.code
  else: status.code

proc waitUntil*(ctx: NativeContext; done: proc(): bool {.closure.};
                timeoutMs = -1): bool =
  ## Pump the central reaper until `done` holds or the timeout expires.
  ## A negative timeout waits indefinitely. Never calls waitpid itself.
  # Wall time, not a count of the 5 ms sleeps: time spent inside `pump` (which
  # may run other operations) counts against the timeout too.
  let start = getMonoTime()
  while true:
    ctx.pump()
    if done(): return true
    if timeoutMs >= 0 and (getMonoTime() - start).inMilliseconds >= timeoutMs: return false
    sleep(5)

# ---------------------------------------------------------------------------
# Unit processes

type
  CommandLine* = object
    executable*: string
    arguments*: seq[string]

proc envValue(environment: openArray[EnvPair], key: string): string =
  for (k, v) in environment:
    if k == key: result = v

proc isExecutableFile(path: string): bool =
  var st: Stat
  if stat(path.cstring, st) != 0: return false
  S_ISREG(st.st_mode) and access(path.cstring, X_OK) == 0

proc resolveCommand*(command: string; environment: openArray[EnvPair]): CommandLine =
  ## Split a decfile command without a shell (as the historical `execDirect`
  ## did) and find the executable in the unit environment's PATH.
  if command.isEmptyOrWhitespace: raise newException(ValueError, "empty command")
  let parts = parseCmdLine(command)
  if parts.len == 0: raise newException(ValueError, "empty command")
  result.arguments = parts[1 .. ^1]
  if '/' in parts[0]:
    if not isExecutableFile(parts[0]):
      raise newException(OSError, "executable not found: " & parts[0])
    result.executable = parts[0]
    return
  for dir in envValue(environment, "PATH").split(':'):
    if dir.len == 0: continue
    let candidate = dir / parts[0]
    if isExecutableFile(candidate):
      result.executable = candidate
      return
  raise newException(OSError, "executable not found in PATH: " & parts[0])

proc spawnUnitProcess*(ctx: NativeContext; command: string; terminal: bool;
                       cgroup: string; owner: string;
                       callback: ChildCallback): Pid =
  ## Start one process of a native unit. Raises OSError/ValueError (or
  ## SpawnError) when the command cannot be resolved or the process cannot be
  ## created.
  ##
  ## Ordinary units get a new session and /dev/null on stdin, stdout, and
  ## stderr: their output was always discarded. `terminal: true` services stay
  ## in PID 1's session and process group and inherit its terminal
  ## (jumpstart_dec(5)).
  let line = resolveCommand(command, ctx.environment)
  var spec = ProcessSpec(executable: line.executable, arguments: line.arguments,
    environment: ctx.environment, workingDirectory: ctx.workingDirectory,
    cgroupProcs: (if cgroup.len > 0: cgroup / "cgroup.procs" else: ""))
  if terminal:
    spec.keepSession = true
    spec.inheritStdio = true
    let term = getEnv("TERM")
    var hasTerm = false
    for (key, _) in spec.environment:
      if key == "TERM": hasTerm = true
    if not hasTerm and term.len > 0: spec.environment.add(("TERM", term))
  else:
    spec.nullStdio = true
  spawn(spec, ctx.reaper, owner, callback).pid

proc runToCompletion*(ctx: NativeContext; command: string; owner: string;
                      cgroup = ""; timeoutMs = -1): ChildStatus =
  ## Run a helper command (execPre, `mount -a`) and wait for its exit through
  ## the central reaper. Raises OSError on timeout.
  var done = false
  var status: ChildStatus
  let pid = ctx.spawnUnitProcess(command, false, cgroup, owner,
    proc(s: ChildStatus) =
      status = s
      done = true)
  if not ctx.waitUntil(proc(): bool = done, timeoutMs):
    discard kill(pid, SIGKILL)
    discard ctx.waitUntil(proc(): bool = done, 1000)
    raise newException(OSError, "timed out waiting for " & command)
  status
