## PAM session notifier for Jumpstart (§7.6).
##
## On session open and close the module sends one session request (§14.5) to
## the system socket, as root, with the user's UID and an opaque session
## identifier. The identifier is created at open and kept in the PAM handle
## (`pam_set_data`), so the close sent for the same transaction carries the
## same identifier even when the application closes the session from a
## forked process. Login never fails because of Jumpstart: every entry point
## returns PAM_SUCCESS and failures are logged to syslog (authpriv).
##
## The request construction, identifier and transport are independent of PAM
## so they can be tested without PAM. Build the module with
## `-d:pamJumpstartModule --app:lib --noMain:on`. Without a Nim main no
## module initialisation runs, so the module uses no Nim globals that need
## it and resolves the PAM functions it calls with `dlsym` at call time from
## the libpam already loaded by the application; no PAM headers or link-time
## libpam are needed.
import std/[json, posix, strutils]

const
  SystemSocketPath* = "/run/jumpstart.sock"
  PamClientName* = "pam_jumpstart"
  PamClientVersion* = "8.0"
  MaxPamResponseBytes* = 1024 * 1024
  DaemonSocketWaitMs* = 10_000
    ## §7.6 step 4.5: the daemon waits up to 10 s for the user socket.
  ResponseTimeoutMs* = 15_000
    ## How long the module waits for the answer: longer than the daemon's
    ## own socket wait plus its spawn work, so a slow user daemon start is
    ## answered rather than cut off by a closed connection.
  SessionDataName* = "jumpstart-session-id"

type
  SessionAction* = enum
    sessionOpen, sessionClose

  SessionSender* = proc(requestLine: string): bool {.closure.}

proc actionName(action: SessionAction): string =
  case action
  of sessionOpen: "open"
  of sessionClose: "close"

proc buildSessionRequest*(action: SessionAction; uid: uint32;
                          sessionId: string): string =
  ## Construct the one-line §14.5 request.  uid and sessionId come from PAM;
  ## sessionId is opaque to both this helper and the daemon protocol.
  if sessionId.len == 0:
    raise newException(ValueError, "session identifier must not be empty")
  result = $(%* {
    "client": {"name": PamClientName, "version": PamClientVersion},
    "session": {
      "action": actionName(action),
      "uid": uid,
      "id": sessionId
    }
  })
  result.add '\n'

proc buildSessionId*(pamhAddress: uint; processId: int): string =
  ## Handle address and opening process: unique among live transactions.
  "pam-" & toHex(pamhAddress) & "-" & $processId

proc buildSessionId*(pamhAddress: uint; processId: int; nonce: uint64): string =
  ## As above plus a random nonce, so a handle address reused by a later
  ## transaction of the same process never repeats an identifier.
  buildSessionId(pamhAddress, processId) & "-" & toHex(nonce)

proc randomNonce*(): uint64 =
  ## 64 bits from /dev/urandom; the monotonic clock if that is unavailable.
  let fd = posix.open("/dev/urandom", O_RDONLY or O_CLOEXEC)
  if fd >= 0:
    let n = posix.read(fd, addr result, sizeof(result))
    discard posix.close(fd)
    if n == sizeof(result): return
  var ts: Timespec
  discard clock_gettime(CLOCK_MONOTONIC, ts)
  uint64(ts.tv_sec) * 1_000_000_000'u64 + uint64(ts.tv_nsec)

proc sessionIdFor*(action: SessionAction; stored: string;
                   fresh: proc(): string): tuple[id: string, store: bool] =
  ## Open: a new identifier, to be stored in the handle. Close: the stored
  ## identifier, or "" when the open never stored one (nothing to close; the
  ## daemon also closes a session when its opener exits, §7.6 step 3).
  case action
  of sessionOpen: (fresh(), true)
  of sessionClose: (stored, false)

proc responseIsSuccess*(line: string): bool =
  ## PAM only needs to know whether the daemon accepted the notification.
  ## Parsing stays strict enough that truncated/arbitrary replies are failures.
  try:
    let node = parseJson(line)
    node.kind == JObject and node.hasKey("type") and
      node["type"].kind == JString and node["type"].getStr == "response" and
      node.hasKey("status") and node["status"].kind == JString and
      node["status"].getStr == "ok"
  except CatchableError:
    false

proc notifySession*(action: SessionAction; uid: uint32; sessionId: string;
                    sender: SessionSender): bool =
  ## Injectable policy helper.  Exceptions are converted to failure so a PAM
  ## entry point can unconditionally return PAM_SUCCESS (fail-open login).
  if sender.isNil: return false
  try:
    sender(buildSessionRequest(action, uid, sessionId))
  except CatchableError:
    false

when defined(linux):
  var MsgNoSignal {.importc: "MSG_NOSIGNAL", header: "<sys/socket.h>".}: cint
else:
  var SoNoSigpipe {.importc: "SO_NOSIGPIPE", header: "<sys/socket.h>".}: cint

proc monotonicMs(): int64 =
  var ts: Timespec
  discard clock_gettime(CLOCK_MONOTONIC, ts)
  int64(ts.tv_sec) * 1000 + int64(ts.tv_nsec) div 1_000_000

proc sendToSystemSocketDetailed*(requestLine: string; socketPath: string;
                                 detail: var string;
                                 timeoutMs = ResponseTimeoutMs): bool =
  ## Send exactly one request on exactly one Unix-domain connection and wait
  ## up to `timeoutMs` for the one response line. Never raises SIGPIPE in
  ## the host process and never changes its credentials.
  var address: Sockaddr_un
  if socketPath.len == 0 or socketPath.len >= sizeof(address.sun_path):
    detail = "invalid socket path"
    return false
  let fd = posix.socket(AF_UNIX, SOCK_STREAM, 0)
  if fd == SocketHandle(-1):
    detail = "socket: " & $strerror(errno)
    return false
  defer: discard posix.close(fd)
  discard fcntl(cint(fd), F_SETFD, FD_CLOEXEC)
  var sendFlags = 0.cint
  when defined(linux):
    sendFlags = MsgNoSignal
  else:
    var one = 1.cint
    discard setsockopt(fd, SOL_SOCKET, SoNoSigpipe, addr one, SockLen(sizeof(one)))
  address.sun_family = TSa_Family(AF_UNIX)
  for i, c in socketPath: address.sun_path[i] = c
  while connect(fd, cast[ptr SockAddr](addr address), SockLen(sizeof(address))) != 0:
    if errno != EINTR:
      detail = "connect " & socketPath & ": " & $strerror(errno)
      return false
  var sent = 0
  while sent < requestLine.len:
    let n = send(fd, unsafeAddr requestLine[sent], requestLine.len - sent, sendFlags)
    if n < 0:
      if errno == EINTR: continue
      detail = "send: " & $strerror(errno)
      return false
    sent += n
  let deadline = monotonicMs() + timeoutMs
  var response = ""
  var buffer: array[4096, char]
  while true:
    let newline = response.find('\n')
    if newline >= 0:
      response.setLen(newline)
      break
    if response.len > MaxPamResponseBytes:
      detail = "response too long"
      return false
    let remaining = deadline - monotonicMs()
    if remaining <= 0:
      detail = "no response within " & $(timeoutMs div 1000) & " s"
      return false
    var pfd = TPollfd(fd: cint(fd), events: POLLIN)
    let ready = poll(addr pfd, 1, cint(remaining))
    if ready < 0:
      if errno == EINTR: continue
      detail = "poll: " & $strerror(errno)
      return false
    if ready == 0: continue
    let n = recv(fd, addr buffer[0], buffer.len, 0)
    if n < 0:
      if errno == EINTR: continue
      detail = "recv: " & $strerror(errno)
      return false
    if n == 0:
      detail = "connection closed without a response"
      return false
    let start = response.len
    response.setLen(start + n)
    copyMem(addr response[start], addr buffer[0], n)
  result = responseIsSuccess(response)
  if not result: detail = "response rejected: " & response

proc sendToSystemSocket*(requestLine: string;
                         socketPath = SystemSocketPath;
                         timeoutMs = ResponseTimeoutMs): bool =
  var detail = ""
  sendToSystemSocketDetailed(requestLine, socketPath, detail, timeoutMs)

when defined(pamJumpstartModule):
  ## Minimal Linux-PAM/OpenPAM C ABI, resolved with dlsym at call time.
  type
    PamHandle = object
    PamCleanup = proc(pamh: ptr PamHandle; data: pointer; errorStatus: cint) {.cdecl.}
    PamGetItem = proc(pamh: ptr PamHandle; itemType: cint; item: ptr pointer): cint {.cdecl.}
    PamSetData = proc(pamh: ptr PamHandle; name: cstring; data: pointer;
                      cleanup: PamCleanup): cint {.cdecl.}
    PamGetData = proc(pamh: ptr PamHandle; name: cstring; data: ptr pointer): cint {.cdecl.}

  const
    PamSuccess = 0.cint
    PamUser = 2.cint          # PAM_USER in Linux-PAM and OpenPAM
    LogAuthpriv = 10 shl 3    # LOG_AUTHPRIV
    LogWarning = 4

  var RtldNoload {.importc: "RTLD_NOLOAD", header: "<dlfcn.h>".}: cint
  proc cStrdup(s: cstring): pointer {.importc: "strdup", header: "<string.h>".}
  proc cFree(p: pointer) {.importc: "free", header: "<stdlib.h>".}
  proc cSyslog(priority: cint; format: cstring) {.importc: "syslog",
      header: "<syslog.h>", varargs.}

  proc pamSymbol(name: cstring): pointer =
    ## libpam is already loaded by the application; never load it here.
    for library in ["libpam.so.0", "libpam.so", "libpam.2.dylib", "libpam.dylib"]:
      let handle = dlopen(library.cstring, RTLD_NOW or RtldNoload)
      if handle != nil:
        result = dlsym(handle, name)
        discard dlclose(handle)
        if result != nil: return
    let global = dlopen(nil, RTLD_NOW)
    if global != nil: result = dlsym(global, name)

  proc logWarning(message: string) =
    cSyslog(cint(LogAuthpriv or LogWarning), "pam_jumpstart: %s", message.cstring)

  proc freeSessionId(pamh: ptr PamHandle; data: pointer; errorStatus: cint) {.cdecl.} =
    if data != nil: cFree(data)

  proc pamNotify(pamh: ptr PamHandle; action: SessionAction) =
    ## Best effort by design.  It does not call seteuid, setuid, setgid, or
    ## any capability API to gain socket access.
    if pamh.isNil: return
    try:
      let getItem = cast[PamGetItem](pamSymbol("pam_get_item"))
      let setData = cast[PamSetData](pamSymbol("pam_set_data"))
      let getData = cast[PamGetData](pamSymbol("pam_get_data"))
      if getItem.isNil or setData.isNil or getData.isNil:
        logWarning("PAM functions not found; session not reported")
        return
      var user: pointer
      if getItem(pamh, PamUser, addr user) != PamSuccess or user.isNil:
        logWarning("no PAM user; session not reported")
        return
      let entry = getpwnam(cast[cstring](user))
      if entry.isNil:
        logWarning("unknown user " & $cast[cstring](user) & "; session not reported")
        return
      let uid = uint32(entry.pw_uid)
      var stored: pointer
      let storedId = if getData(pamh, SessionDataName, addr stored) == PamSuccess and
                        not stored.isNil: $cast[cstring](stored) else: ""
      let (sessionId, store) = sessionIdFor(action, storedId, proc(): string =
        buildSessionId(cast[uint](pamh), int(getpid()), randomNonce()))
      if sessionId.len == 0: return
      if store:
        let copy = cStrdup(sessionId.cstring)
        if copy.isNil or setData(pamh, SessionDataName, copy, freeSessionId) != PamSuccess:
          if not copy.isNil: cFree(copy)
          logWarning("cannot keep the session identifier; close will not match")
      var detail = ""
      let ok = notifySession(action, uid, sessionId, proc(line: string): bool =
        sendToSystemSocketDetailed(line, SystemSocketPath, detail))
      if not ok:
        logWarning("session " & actionName(action) & " for UID " & $uid &
                   " not accepted: " & detail)
    except CatchableError as error:
      logWarning("session " & actionName(action) & " failed: " & error.msg)

  proc pam_sm_open_session*(pamh: ptr PamHandle; flags, argc: cint;
                            argv: ptr cstring): cint
      {.cdecl, exportc, dynlib.} =
    discard flags
    discard argc
    discard argv
    pamNotify(pamh, sessionOpen)
    PamSuccess

  proc pam_sm_close_session*(pamh: ptr PamHandle; flags, argc: cint;
                             argv: ptr cstring): cint
      {.cdecl, exportc, dynlib.} =
    discard flags
    discard argc
    discard argv
    pamNotify(pamh, sessionClose)
    PamSuccess
