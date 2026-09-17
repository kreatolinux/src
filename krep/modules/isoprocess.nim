## Checked, shell-free commands for the ISO builder.
##
## Cancellation scopes are process-global and must be used on the main thread.
## SIGINT/SIGTERM handlers only set a flag: cleanup runs in ordinary Nim code.
import std/[os, osproc]
when defined(posix):
  import std/posix

when defined(posix):
  var cancelRequested {.volatile.}: Sig_atomic
  var previousInt, previousTerm: Sigaction
else:
  var cancelRequested {.volatile.}: cint
var cancellationDepth = 0

proc requestCancel*() {.raises: [].} =
  ## Request cancellation without sending a signal (also useful in tests).
  cancelRequested = 1

proc checkCancellation*() {.raises: [IOError].} =
  ## Check between CPU/file-copy stages as well as inside checkedRun.
  if cancelRequested != 0:
    raise newException(IOError, "ISO build cancelled")

when defined(posix):
  proc cancellationHandler(signal: cint) {.noconv, raises: [],
      stackTrace: off, lineTrace: off.} =
    cancelRequested = 1

proc beginCancellation*() =
  ## Install temporary handlers. Nested scopes preserve the outer request.
  if cancellationDepth == 0:
    cancelRequested = 0
    when defined(posix):
      var action: Sigaction
      action.sa_handler = cancellationHandler
      discard sigemptyset(action.sa_mask)
      action.sa_flags = 0
      if sigaction(SIGINT, action, previousInt) != 0:
        raiseOSError(osLastError())
      if sigaction(SIGTERM, action, previousTerm) != 0:
        let error = osLastError()
        discard sigaction(SIGINT, previousInt)
        raiseOSError(error)
  inc cancellationDepth

proc endCancellation*() =
  ## Restore the exact previous actions, including their masks and flags.
  if cancellationDepth == 0:
    return
  dec cancellationDepth
  if cancellationDepth == 0:
    when defined(posix):
      discard sigaction(SIGTERM, previousTerm)
      discard sigaction(SIGINT, previousInt)
    cancelRequested = 0

template withCancellation*(body: untyped) =
  beginCancellation()
  try:
    body
  finally:
    endCancellation()

proc reap(child: Process) =
  while true:
    try:
      discard child.waitForExit()
      return
    except OSError as error:
      when defined(posix):
        if error.errorCode == EINTR:
          continue
      raise

proc stopChild(child: Process, isolatedGroup: bool) =
  ## Give ordinary descendants time to exit before killing the whole group.
  ## Descendants that deliberately create a new session can escape this group.
  when defined(posix):
    let pid = Pid(child.processID)
    let target = if isolatedGroup: -pid else: pid
    discard posix.kill(target, SIGTERM)
    for attempt in 0..<10:
      # Always give group members their grace period, even if the leader exits.
      if not isolatedGroup and child.peekExitCode() != -1:
        break
      sleep(25)
    discard posix.kill(target, SIGKILL)
  else:
    child.terminate()
    for attempt in 0..<10:
      if child.peekExitCode() != -1:
        break
      sleep(25)
    if child.peekExitCode() == -1:
      child.kill()
  reap(child)

proc checkedRun*(exe: string, args: seq[string]) =
  ## Execute argv directly, with inherited stdin/stdout/stderr. Never use a shell.
  ## Nonzero exit and cancellation raise IOError, so caller finally blocks run.
  ## On POSIX, poDaemon requests an isolated process group through posix_spawn.
  ## Non-POSIX and Nim builds forced to use fork may only stop the direct child.
  if cancelRequested != 0:
    raise newException(IOError, "Command cancelled: " & exe)
  let child = startProcess(exe, args = args,
      options = {poUsePath, poParentStreams, poDaemon})
  var finished = false
  var isolatedGroup = false
  when defined(posix):
    # Never send a negative-PID signal unless this is the child's own group.
    isolatedGroup = getpgid(Pid(child.processID)) == Pid(child.processID)
  try:
    while true:
      if cancelRequested != 0:
        raise newException(IOError, "Command cancelled: " & exe)
      let status = child.peekExitCode()
      if status != -1:
        finished = true
        if status != 0:
          raise newException(IOError,
              "Command failed (exit " & $status & "): " & exe)
        return
      # Nim's timed waitForExit KILLS the command on timeout. Use its nonblocking
      # peekExitCode (waitpid WNOHANG) instead, then reap after termination.
      sleep(25)
  finally:
    try:
      if not finished:
        stopChild(child, isolatedGroup)
    finally:
      child.close()
