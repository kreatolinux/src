## Stopping and signalling native services.
##
## Stop sends SIGTERM to the main process, waits (through the central reaper)
## up to `stopTimeoutMs`, sends SIGKILL, and then kills the unit's cgroup
## (§15.1 rule 6), which reaches every remaining process of the service.
## Nothing here calls waitpid, `running()` or `waitForExit`.
import std/[os, posix, strutils]
import ../../common/logging
import jumpstartcore/[cgroups, errors]
import globalVariables, start, status

proc parseSignal*(text: string): cint =
  ## `SIGHUP`, `HUP`, or a decimal number (§21.2). Raises E_USAGE.
  let value = text.strip
  if value.len > 0 and value.allCharsInSet(Digits):
    let n = try: parseInt(value) except ValueError: -1
    if n <= 0 or n > 64: nativeFail(ecUsage, "invalid signal number: " & text)
    return cint(n)
  var name = value.toUpperAscii
  if name.startsWith("SIG"): name = name[3 .. ^1]
  case name
  of "HUP": SIGHUP
  of "INT": SIGINT
  of "QUIT": SIGQUIT
  of "ILL": SIGILL
  of "TRAP": SIGTRAP
  of "ABRT", "IOT": SIGABRT
  of "BUS": SIGBUS
  of "FPE": SIGFPE
  of "KILL": SIGKILL
  of "USR1": SIGUSR1
  of "SEGV": SIGSEGV
  of "USR2": SIGUSR2
  of "PIPE": SIGPIPE
  of "ALRM": SIGALRM
  of "TERM": SIGTERM
  of "CHLD": SIGCHLD
  of "CONT": SIGCONT
  of "STOP": SIGSTOP
  of "TSTP": SIGTSTP
  of "TTIN": SIGTTIN
  of "TTOU": SIGTTOU
  of "URG": SIGURG
  of "XCPU": SIGXCPU
  of "XFSZ": SIGXFSZ
  of "VTALRM": SIGVTALRM
  of "PROF": SIGPROF
  of "SYS": SIGSYS
  else: nativeFail(ecUsage, "unknown signal: " & text)

proc killUnitProcesses(ctx: NativeContext; record: ServiceRecord) =
  ## §15.1 rule 6: after the stop sequence, kill and remove the unit cgroup.
  if record.cgroup.len == 0 or ctx.cgroups.isNone: return
  try: killUnitCgroup(record.cgroup, ctx.cgroupSystem)
  except CatchableError as e:
    warn "Could not kill cgroup of " & record.name & ": " & e.msg

proc stopService*(ctx: NativeContext; serviceName: string) =
  ## Stop a service. Stopping a service that is not running is a success.
  let record = ctx.findService(serviceName)
  if record.isNil or not record.running:
    if not record.isNil:
      # A oneshot that already exited, or a crashed daemon, may still have
      # processes in its cgroup.
      ctx.killUnitProcesses(record)
    info "Service " & serviceName & " is already not running, not trying to stop"
    return

  info "Stopping service " & serviceName
  info "PID: " & $record.pid
  record.requestedStop = true
  if kill(record.pid, SIGTERM) != 0 and osLastError() != OSErrorCode(ESRCH):
    warn "Could not send SIGTERM to " & serviceName & ": " & osErrorMsg(osLastError())
  if not ctx.waitUntil(proc(): bool = not record.running, ctx.stopTimeoutMs):
    debug "Killing process after stop timeout"
    discard kill(record.pid, SIGKILL)
    if not ctx.waitUntil(proc(): bool = not record.running, ctx.stopTimeoutMs):
      nativeFail(ecPartial, "service " & serviceName &
        " did not exit after SIGKILL (pid " & $record.pid & ")")
  # A clean exit may run execPost; let it finish before the cgroup is killed.
  discard ctx.waitUntil(proc(): bool = not record.postRunning, ctx.stopTimeoutMs)
  ctx.killUnitProcesses(record)
  info "Service " & serviceName & " stopped"

proc killService*(ctx: NativeContext; serviceName: string; signal: string) =
  ## `service.kill`: signal every process in the unit's cgroup, or only the
  ## main process without cgroup v2. Never signals a process group, because
  ## `terminal: true` services share PID 1's process group (Appendix A).
  let sig = parseSignal(signal)
  let record = ctx.findService(serviceName)
  var pids: seq[int]
  if not record.isNil: pids = ctx.cgroupPids(record.cgroup)
  if pids.len == 0:
    if record.isNil or not record.running:
      nativeFail(ecUnitState, "service " & serviceName & " is not running")
    pids = @[int(record.pid)]
  for pid in pids:
    if pid <= 1: continue
    if kill(Pid(pid), sig) != 0 and osLastError() != OSErrorCode(ESRCH):
      nativeFail(ecPermission, "cannot signal pid " & $pid & ": " &
        osErrorMsg(osLastError()))
  info "Sent signal " & signal & " to " & serviceName
