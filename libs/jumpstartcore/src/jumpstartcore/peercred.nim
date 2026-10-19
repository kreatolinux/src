## Peer credentials, pidfds and /proc process identity (§7.4, §7.6 step 3,
## §15.3). Linux uses SO_PEERCRED/SO_PEERPIDFD/pidfd_open; macOS provides
## getpeereid + LOCAL_PEERPID so the daemon's peer checks compile and run on
## development hosts. /proc readers take an injectable root for tests.
import std/[os, strutils]
import posix

type
  PeerCredentialsInfo* = object
    uid*, gid*: int64
    pid*: int    ## 0 when the platform cannot report the peer PID.

when defined(linux):
  {.emit: """
#define _GNU_SOURCE
#include <errno.h>
#include <poll.h>
#include <signal.h>
#include <time.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#ifndef SO_PEERPIDFD
#define SO_PEERPIDFD 77
#endif
static int js_peercred(int fd, long long *uid, long long *gid, int *pid) {
  struct ucred cred; socklen_t len = sizeof(cred);
  if (getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred, &len) != 0) return -1;
  *uid = cred.uid; *gid = cred.gid; *pid = cred.pid; return 0;
}
static int js_peerpidfd(int fd) {
  int pidfd = -1; socklen_t len = sizeof(pidfd);
  if (getsockopt(fd, SOL_SOCKET, SO_PEERPIDFD, &pidfd, &len) != 0) return -1;
  return pidfd;
}
static int js_pidfd_open(int pid) { return (int)syscall(434, pid, 0); }
static int js_pidfd_send_signal(int pidfd, int sig) {
  return (int)syscall(424, pidfd, sig, NULL, 0);
}
static long long js_boottime_ticks(void) {
  struct timespec ts; long hz = sysconf(_SC_CLK_TCK);
  if (clock_gettime(CLOCK_BOOTTIME, &ts) != 0 || hz <= 0) return -1;
  return (long long)ts.tv_sec * hz + (long long)ts.tv_nsec / (1000000000LL / hz);
}
""".}
  proc cPeerCred(fd: cint; uid, gid: ptr int64; pid: ptr cint): cint
    {.importc: "js_peercred", nodecl.}
  proc cPeerPidfd(fd: cint): cint {.importc: "js_peerpidfd", nodecl.}
  proc cPidfdOpen(pid: cint): cint {.importc: "js_pidfd_open", nodecl.}
  proc cPidfdSendSignal(fd, sig: cint): cint {.importc: "js_pidfd_send_signal", nodecl.}
  proc cBoottimeTicks(): int64 {.importc: "js_boottime_ticks", nodecl.}
elif defined(macosx):
  {.emit: """
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#ifndef LOCAL_PEERPID
#define LOCAL_PEERPID 0x002
#endif
static int js_peercred(int fd, long long *uid, long long *gid, int *pid) {
  uid_t u; gid_t g; pid_t p = 0; socklen_t len = sizeof(p);
  if (getpeereid(fd, &u, &g) != 0) return -1;
  if (getsockopt(fd, 0 /* SOL_LOCAL */, LOCAL_PEERPID, &p, &len) != 0) p = 0;
  *uid = u; *gid = g; *pid = p; return 0;
}
""".}
  proc cPeerCred(fd: cint; uid, gid: ptr int64; pid: ptr cint): cint
    {.importc: "js_peercred", nodecl.}

proc peerCredentials*(fd: cint): PeerCredentialsInfo =
  ## SO_PEERCRED on Linux, getpeereid/LOCAL_PEERPID on macOS.
  when defined(linux) or defined(macosx):
    var uid, gid: int64
    var pid: cint
    if cPeerCred(fd, addr uid, addr gid, addr pid) != 0:
      raiseOSError(osLastError(), "peer credentials")
    PeerCredentialsInfo(uid: uid, gid: gid, pid: int(pid))
  else:
    raise newException(OSError, "peer credentials are unsupported on this platform")

proc peerPidfd*(fd: cint): cint =
  ## SO_PEERPIDFD (Linux >= 6.5). -1 when the kernel does not support it.
  when defined(linux):
    let pidfd = cPeerPidfd(fd)
    if pidfd < 0:
      let err = osLastError()
      if err in [OSErrorCode(ENOPROTOOPT), OSErrorCode(EINVAL), OSErrorCode(EOPNOTSUPP)]:
        return -1
      raiseOSError(err, "SO_PEERPIDFD")
    discard fcntl(pidfd, F_SETFD, FD_CLOEXEC)
    pidfd
  else:
    discard fd
    -1

proc pidfdOpen*(pid: int): cint =
  ## pidfd_open(2). -1 when unsupported (ENOSYS); raises for other errors
  ## (ESRCH: the process is gone).
  when defined(linux):
    if pid <= 0: raise newException(ValueError, "invalid pid")
    let fd = cPidfdOpen(cint(pid))
    if fd < 0:
      let err = osLastError()
      if err == OSErrorCode(ENOSYS): return -1
      raiseOSError(err, "pidfd_open")
    discard fcntl(fd, F_SETFD, FD_CLOEXEC)
    fd
  else:
    discard pid
    -1

proc pidfdSendSignal*(pidfd: cint; signal: cint): bool =
  ## pidfd_send_signal(2). False when the process has already exited (ESRCH).
  when defined(linux):
    if cPidfdSendSignal(pidfd, signal) == 0: return true
    let err = osLastError()
    if err == OSErrorCode(ESRCH): return false
    raiseOSError(err, "pidfd_send_signal")
  else:
    discard pidfd
    discard signal
    raise newException(OSError, "pidfds are unavailable on this platform")

proc pidfdExited*(pidfd: cint): bool =
  ## A pidfd becomes readable when its process exits (§7.6 step 3).
  if pidfd < 0: return false
  var pfd = TPollfd(fd: pidfd, events: POLLIN)
  while true:
    let n = poll(addr pfd, 1, 0)
    if n < 0 and osLastError() == OSErrorCode(EINTR): continue
    if n < 0: raiseOSError(osLastError(), "poll pidfd")
    return n > 0 and (pfd.revents and (POLLIN or POLLHUP)) != 0

proc parseStatStartTime*(stat: string): int64 =
  ## Field 22 (starttime, clock ticks since boot) of /proc/PID/stat. The comm
  ## field may contain spaces and parentheses, so parse after the last ')'.
  let close = stat.rfind(')')
  if close < 0: raise newException(ValueError, "malformed /proc stat")
  let fields = stat[close + 1 .. ^1].splitWhitespace
  # fields[0] is field 3 (state); field 22 is index 19.
  if fields.len < 20: raise newException(ValueError, "malformed /proc stat")
  parseBiggestInt(fields[19])

proc parseStatState*(stat: string): char =
  let close = stat.rfind(')')
  if close < 0: raise newException(ValueError, "malformed /proc stat")
  let fields = stat[close + 1 .. ^1].splitWhitespace
  if fields.len < 1 or fields[0].len != 1: raise newException(ValueError, "malformed /proc stat")
  fields[0][0]

proc parseStatFlags*(stat: string): uint64 =
  ## Field 9 (flags). PF_KTHREAD (0x00200000) marks kernel threads.
  let close = stat.rfind(')')
  if close < 0: raise newException(ValueError, "malformed /proc stat")
  let fields = stat[close + 1 .. ^1].splitWhitespace
  if fields.len < 7: raise newException(ValueError, "malformed /proc stat")
  uint64(parseBiggestUInt(fields[6]))

proc parseStatusRealUid*(status: string): int64 =
  for line in status.splitLines:
    if line.startsWith("Uid:"):
      let fields = line[4 .. ^1].splitWhitespace
      if fields.len >= 1: return parseBiggestInt(fields[0])
  raise newException(ValueError, "malformed /proc status")

proc processStartTicks*(pid: int; procRoot = "/proc"): int64 =
  parseStatStartTime(readFile(procRoot / $pid / "stat"))

proc processRealUid*(pid: int; procRoot = "/proc"): int64 =
  parseStatusRealUid(readFile(procRoot / $pid / "status"))

proc bootTimeTicks*(): int64 =
  ## Current CLOCK_BOOTTIME in clock ticks: the unit of /proc/PID/stat field
  ## 22, so a connection's acceptance time can be compared with a peer's start.
  when defined(linux):
    result = cBoottimeTicks()
    if result < 0: raiseOSError(osLastError(), "CLOCK_BOOTTIME")
  else:
    raise newException(OSError, "boot-time clock ticks require Linux")
