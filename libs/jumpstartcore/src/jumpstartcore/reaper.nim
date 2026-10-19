## Central SIGCHLD-driven child registry and cancellation primitives (§15.3).
## The signal handler only writes to a nonblocking self-pipe. Event-loop code
## owns waitpid and callback delivery: poll `wakeupFd`, then `drainWakeup`.
##
## PID reuse: a registered child cannot be reused by the kernel until this
## reaper has waited for it, so `signalChild` (which refuses unregistered or
## already-reaped PIDs) is race-free when called from the reaping thread. Where
## pidfds exist the reaper also holds one per child and signals through it.
import std/[os, tables, times, monotimes]
import posix
import ./peercred

type
  ChildExitKind* = enum
    cekExited, cekSignaled, cekStopped, cekContinued, cekUnknown
  ChildStatus* = object
    pid*: Pid
    raw*: cint
    kind*: ChildExitKind
    code*: int
    coreDumped*: bool
  ChildCallback* = proc(status: ChildStatus) {.closure.}
  UnownedCallback* = proc(status: ChildStatus) {.closure.}
  ChildRegistration = object
    owner: string
    callback: ChildCallback
    pidfd: cint
  Reaper* = ref object
    children: Table[Pid, ChildRegistration]
    completed: Table[Pid, ChildStatus]
    unownedReaped*: int
      ## Count of exited children nobody registered (orphans reparented to us).
    onUnowned*: UnownedCallback
      ## Called for each unowned child; the daemon logs it at debug (§15.3).
    waitErrors*: int
      ## waitpid failures other than EINTR/ECHILD. `drain` never raises: the
      ## daemon is PID 1 and a failing wait must not take it down.
    lastWaitError*: string
    wakeRead, wakeWrite: cint

var signalWakeFd = -1.cint

proc closeFd(fd: cint) {.inline.} =
  if fd >= 0: discard close(fd)

proc setFdFlags(fd: cint, command, flag: cint) =
  let old = fcntl(fd, command, 0)
  if old < 0: raiseOSError(osLastError())
  let setCommand = if command == F_GETFD: F_SETFD else: F_SETFL
  if fcntl(fd, setCommand, old or flag) < 0: raiseOSError(osLastError())

proc newReaper*(): Reaper =
  var wake: array[2, cint]
  if pipe(wake) != 0: raiseOSError(osLastError())
  try:
    setFdFlags(wake[0], F_GETFD, FD_CLOEXEC)
    setFdFlags(wake[1], F_GETFD, FD_CLOEXEC)
    setFdFlags(wake[0], F_GETFL, O_NONBLOCK)
    setFdFlags(wake[1], F_GETFL, O_NONBLOCK)
  except:
    closeFd(wake[0]); closeFd(wake[1]); raise
  new(result)
  result.children = initTable[Pid, ChildRegistration]()
  result.completed = initTable[Pid, ChildStatus]()
  result.wakeRead = wake[0]
  result.wakeWrite = wake[1]

proc close*(r: Reaper) =
  if r.isNil: return
  if signalWakeFd == r.wakeWrite: signalWakeFd = -1
  for registration in r.children.values: closeFd(registration.pidfd)
  closeFd(r.wakeRead); closeFd(r.wakeWrite)
  r.wakeRead = -1; r.wakeWrite = -1

proc decodeStatus*(pid: Pid, raw: cint): ChildStatus =
  result = ChildStatus(pid: pid, raw: raw, kind: cekUnknown)
  let low = int(raw) and 0xff
  if low == 0:
    result.kind = cekExited
    result.code = (int(raw) shr 8) and 0xff
  elif low == 0x7f:
    result.kind = cekStopped
    result.code = (int(raw) shr 8) and 0xff
  elif low == 0xff:
    result.kind = cekContinued
  else:
    result.kind = cekSignaled
    result.code = low and 0x7f
    result.coreDumped = (low and 0x80) != 0

proc register*(r: Reaper, pid: Pid, owner = "", callback: ChildCallback = nil) =
  ## Register before the child can exit (spawn holds it behind a gate). With a
  ## callback the status is delivered only to the callback; without one it is
  ## kept for `takeCompleted`.
  if r.isNil or pid <= 0: raise newException(ValueError, "invalid child registration")
  if r.children.hasKey(pid): raise newException(ValueError, "child is already registered")
  if r.completed.hasKey(pid) and callback != nil:
    let status = r.completed[pid]
    r.completed.del(pid)
    callback(status)
  elif not r.completed.hasKey(pid):
    var fd = -1.cint
    try: fd = pidfdOpen(int(pid))
    except CatchableError: fd = -1
    r.children[pid] = ChildRegistration(owner: owner, callback: callback, pidfd: fd)

proc unregister*(r: Reaper, pid: Pid): bool =
  ## Stop routing this child's exit to its owner. The child is still reaped
  ## (as unowned) when it exits.
  var registration: ChildRegistration
  result = r.children.take(pid, registration)
  if result: closeFd(registration.pidfd)

proc owner*(r: Reaper, pid: Pid): string =
  if r.children.hasKey(pid): r.children[pid].owner else: ""

proc signalChild*(r: Reaper, pid: Pid, signal: cint): bool =
  ## Signal a registered, not yet reaped child. Returns false when the child
  ## is unknown or already exited, so a reused PID is never signalled.
  if r.isNil or not r.children.hasKey(pid): return false
  let fd = r.children[pid].pidfd
  if fd >= 0:
    return pidfdSendSignal(fd, signal)
  if kill(pid, signal) == 0: return true
  if osLastError() == OSErrorCode(ESRCH): return false
  raiseOSError(osLastError())

proc signalChildGroup*(r: Reaper, pid: Pid, signal: cint): bool =
  ## Signal the process group led by a registered child (every core process
  ## runs in its own session). Guarded by registration like signalChild.
  if r.isNil or not r.children.hasKey(pid): return false
  if kill(-pid, signal) == 0: return true
  if osLastError() == OSErrorCode(ESRCH): return false
  raiseOSError(osLastError())

proc isRegistered*(r: Reaper, pid: Pid): bool = r.children.hasKey(pid)
proc registeredCount*(r: Reaper): int = r.children.len
proc takeCompleted*(r: Reaper, pid: Pid, status: var ChildStatus): bool =
  r.completed.take(pid, status)
proc wakeupFd*(r: Reaper): cint = r.wakeRead

proc deliver(r: Reaper, status: ChildStatus) =
  var registration: ChildRegistration
  if r.children.take(status.pid, registration):
    closeFd(registration.pidfd)
    if registration.callback != nil:
      registration.callback(status)
    else:
      r.completed[status.pid] = status
  else:
    inc r.unownedReaped
    if r.onUnowned != nil:
      try: r.onUnowned(status)
      except CatchableError: discard

proc childSignalHandler(signal: cint) {.noconv.} =
  let saved = errno
  if signalWakeFd >= 0:
    var token: char = 'c'
    discard write(signalWakeFd, addr token, 1) # EAGAIN means a wake is pending.
  errno = saved

proc installSigChldHandler*(r: Reaper) =
  ## Register wakeupFd(r) with select/poll/kqueue/epoll, then call drainWakeup.
  ## SA_RESTART keeps unrelated syscalls working; SA_NOCLDSTOP limits wakes to
  ## exits. A wake that interrupts nothing is still visible on wakeupFd.
  if r.isNil or r.wakeWrite < 0: raise newException(ValueError, "invalid reaper")
  signalWakeFd = r.wakeWrite
  var action: Sigaction
  action.sa_handler = childSignalHandler
  discard sigemptyset(action.sa_mask)
  action.sa_flags = SA_RESTART or SA_NOCLDSTOP
  if sigaction(SIGCHLD, action, nil) != 0: raiseOSError(osLastError())

proc sigChldPending*(r: Reaper): bool =
  if r.isNil: return false
  var pfd = TPollfd(fd: r.wakeRead, events: POLLIN)
  poll(addr pfd, 1, 0) > 0 and (pfd.revents and POLLIN) != 0

proc drain*(r: Reaper): int =
  ## The only waitpid site in the cores implementation.
  if r.isNil: return 0
  while true:
    var raw: cint
    let pid = waitpid(Pid(-1), raw, WNOHANG)
    if pid > 0:
      r.deliver(decodeStatus(pid, raw)); inc result
    elif pid == 0: break
    else:
      let err = osLastError()
      if err == OSErrorCode(EINTR): continue
      if err == OSErrorCode(ECHILD): break
      inc r.waitErrors
      r.lastWaitError = osErrorMsg(err)
      break

proc drainWakeup*(r: Reaper): int =
  ## Clear the edge before waitpid. A concurrent SIGCHLD writes another edge.
  var buffer: array[64, char]
  while true:
    let n = read(r.wakeRead, addr buffer[0], buffer.len)
    if n > 0: continue
    if n < 0 and osLastError() == OSErrorCode(EINTR): continue
    break
  result = r.drain()

when defined(linux):
  const PrSetChildSubreaper = 36.cint
  proc prctl(option: cint, arg2: culong): cint
    {.importc, header: "<sys/prctl.h>", varargs.}

proc enableChildSubreaper*() =
  when defined(linux):
    if prctl(PrSetChildSubreaper, 1.culong) != 0: raiseOSError(osLastError())
  else:
    raise newException(OSError, "child subreapers are only available on Linux")

proc installReaper*(r: Reaper; isPid1 = getpid() == 1) =
  ## Startup step of §20.2 / §15.3: become a child subreaper unless we are
  ## PID 1 (which is the reaper of last resort already), install the SIGCHLD
  ## self-pipe handler, and reap anything that exited before installation.
  ## The event loop then polls `wakeupFd(r)` and calls `drainWakeup(r)`.
  if r.isNil: raise newException(ValueError, "invalid reaper")
  if not isPid1: enableChildSubreaper()
  installSigChldHandler(r)
  discard r.drain()

type
  CancellationStage* = enum csRunning, csTermSent, csKillSent, csComplete
  Cancellation* = object
    processGroup*: Pid
    stage*: CancellationStage
    killAt*: MonoTime

proc beginCancellation*(processGroup: Pid, now = getMonoTime(),
                        grace = initDuration(seconds = 5)): Cancellation =
  if processGroup <= 0: raise newException(ValueError, "invalid process group")
  if kill(-processGroup, SIGTERM) != 0 and osLastError() != OSErrorCode(ESRCH):
    raiseOSError(osLastError())
  Cancellation(processGroup: processGroup, stage: csTermSent, killAt: now + grace)

proc complete*(c: var Cancellation) = c.stage = csComplete
proc advanceCancellation*(c: var Cancellation, now = getMonoTime()): bool =
  if c.stage == csTermSent and now >= c.killAt:
    if kill(-c.processGroup, SIGKILL) != 0 and osLastError() != OSErrorCode(ESRCH):
      raiseOSError(osLastError())
    c.stage = csKillSent
    return true
