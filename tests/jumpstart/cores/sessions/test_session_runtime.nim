## Linux user-daemon session runtime (§7.6 steps 4-5, §27.2, §27.7). Needs
## root, tmpfs mounts and a `tester` account (UID 1000); cgroup checks run
## when a writable cgroup2 hierarchy is available. Skips cleanly otherwise.
import std/[monotimes, os, osproc, strutils, times, unittest]
import posix
import ../../../../jumpstart/cores/manifest/modes,
  ../../../../jumpstart/cores/sessions/[session_manager, session_runtime_linux, sessions]
import jumpstartcore/[cgroups, reaper]

const FakeDaemon = """
#define _GNU_SOURCE
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
extern char **environ;
static void copy(FILE *out, const char *path, const char *prefix) {
  char line[512]; FILE *in = fopen(path, "r");
  if (!in) return;
  while (fgets(line, sizeof line, in))
    if (!prefix || strncmp(line, prefix, strlen(prefix)) == 0) fputs(line, out);
  fclose(in);
}
int main(int argc, char **argv) {
  const char *home = getenv("HOME"); char path[512], mode[32] = "ok", cwd[512];
  snprintf(path, sizeof path, "%s/report", home);
  FILE *f = fopen(path, "w");
  fprintf(f, "argv1=%s\nuid=%d euid=%d gid=%d\n", argc > 1 ? argv[1] : "",
          getuid(), geteuid(), getgid());
  if (getcwd(cwd, sizeof cwd)) fprintf(f, "cwd=%s\n", cwd);
  for (char **e = environ; *e; e++) fprintf(f, "env:%s\n", *e);
  copy(f, "/proc/self/status", "Cap"); copy(f, "/proc/self/status", "NoNewPrivs");
  copy(f, "/proc/self/status", "Groups"); copy(f, "/proc/self/cgroup", NULL);
  fclose(f);
  snprintf(path, sizeof path, "%s/mode", home);
  FILE *m = fopen(path, "r");
  if (m) { if (fscanf(m, "%31s", mode) != 1) strcpy(mode, "ok"); fclose(m); }
  if (strcmp(mode, "exit") == 0) return 3;
  if (strcmp(mode, "nobind") == 0) for (;;) pause();
  snprintf(path, sizeof path, "%s/.local", home); mkdir(path, 0700);
  snprintf(path, sizeof path, "%s/.local/share", home); mkdir(path, 0700);
  snprintf(path, sizeof path, "%s/.local/share/jumpstart", home); mkdir(path, 0700);
  struct sockaddr_un a; memset(&a, 0, sizeof a); a.sun_family = AF_UNIX;
  snprintf(a.sun_path, sizeof a.sun_path, "%s/.local/share/jumpstart/jumpstart.sock", home);
  int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (bind(fd, (struct sockaddr *)&a, sizeof a) != 0) return errno == EADDRINUSE ? 1 : 2;
  listen(fd, 8);
  for (;;) { int c = accept(fd, NULL, NULL); if (c >= 0) close(c); }
}
"""

proc available(): bool =
  when not defined(linux): false
  else: getuid() == 0 and getpwnam("tester") != nil and findExe("gcc").len > 0

proc liveCgroups(): bool =
  when not defined(linux): return false
  else:
    try:
      fileExists("/sys/fs/cgroup/cgroup.controllers") and
        mountInfoFsType(readFile("/proc/self/mountinfo"), "/sys/fs/cgroup") == "cgroup2"
    except CatchableError: false

suite "Linux user daemon session runtime":
  when not defined(linux):
    test "sessions need Linux":
      expect OSError: discard newLinuxSessionRuntime(LinuxSessionConfig())
  else:
    if not available():
      test "session runtime tests skipped (need root, gcc and a tester account)":
        skip()
    else:
      discard execShellCmd("getent group jstest >/dev/null || groupadd -g 2345 jstest; usermod -aG jstest tester")
      let work = "/tmp/js-session-" & $getpid()
      createDir(work)
      let exe = work / "fake-jumpstart"
      writeFile(work / "fake.c", FakeDaemon)
      doAssert execShellCmd("gcc -O1 -o " & exe & " " & work / "fake.c") == 0
      discard posix.chmod(work.cstring, Mode(0o755))
      let accounts = passwdAccounts()
      let tester = accounts.byName("tester")
      let home = tester.home
      let useCgroups = liveCgroups()
      var usersRoot = ""
      if useCgroups:
        let h = cgroupHierarchy("/sys/fs/cgroup")
        prepareSystemHierarchy(h, defaultCgroupSystem())
        usersRoot = h.users
      let reaper = newReaper()
      let start = getMonoTime()
      var exits: seq[(bool, bool, int)]
      var logs: seq[string]
      var config = defaultLinuxSessionConfig(exe, reaper, usersRoot)
      config.runUserRoot = work / "run-user"
      config.now = proc(): int64 = (getMonoTime() - start).inMilliseconds
      config.pause = proc(ms: int) = sleep(ms)
      config.log = proc(message: string) = logs.add message
      config.onExit = proc(account: AccountInfo; status: ChildStatus;
                           causedBySystem, socketInUse: bool) =
        exits.add((causedBySystem, socketInUse, status.code))
      let runtime = newLinuxSessionRuntime(config)
      let ops = runtime.ops
      let runtimeDir = config.runUserRoot / $tester.uid

      proc setMode(mode: string) =
        writeFile(home / "mode", mode)
        discard posix.chown((home / "mode").cstring, Uid(tester.uid), Gid(tester.gid))
        removeFile(home / ".local/share/jumpstart/jumpstart.sock")

      proc report(): string = readFile(home / "report")

      proc settle(until: proc(): bool) =
        for _ in 0 .. 1500:
          discard reaper.drain()
          runtime.tick()
          if until(): return
          sleep(10)

      test "start: tmpfs, delegated cgroup, dropped credentials, user environment, socket wait":
        setMode("ok")
        check ops.start(tester, srFirstSession) == soStarted
        let info = readFile("/proc/self/mountinfo")
        check isJumpstartRuntimeMount(info, runtimeDir, tester.uid)
        var mountLine = ""
        for line in info.splitLines:
          if (" " & runtimeDir & " ") in line: mountLine = line
        check "nosuid" in mountLine and "nodev" in mountLine
        check "mode=700" in mountLine and ("uid=" & $tester.uid) in mountLine
        check "size=" in mountLine
        let r = report()
        check "argv1=--user" in r
        check ("uid=" & $tester.uid & " euid=" & $tester.uid & " gid=" & $tester.gid) in r
        check ("cwd=" & home) in r
        check "CapEff:\t0000000000000000" in r
        check "CapPrm:\t0000000000000000" in r
        check "CapBnd:\t0000000000000000" in r
        check "CapAmb:\t0000000000000000" in r
        check "NoNewPrivs:\t1" in r
        check "2345" in r                                 # supplementary group
        var env: seq[string]
        for line in r.splitLines:
          if line.startsWith("env:"): env.add line[4 .. ^1].split('=')[0]
        check env.len == 6
        for name in ["HOME", "USER", "LOGNAME", "SHELL", "PATH", "LANG"]:
          check name in env
        if useCgroups:
          check ("0::/jumpstart/users/" & $tester.uid & "/daemon") in r
          var st: Stat
          let user = usersRoot / $tester.uid
          check stat(user.cstring, st) == 0 and st.st_uid == Uid(tester.uid)
          check stat((user / "cgroup.procs").cstring, st) == 0 and st.st_uid == Uid(tester.uid)
          check stat((user / "daemon" / "cgroup.procs").cstring, st) == 0 and st.st_uid == 0
          check stat((user / "memory.max").cstring, st) != 0 or st.st_uid == 0
        check runtime.userPid(tester.uid) > 1

      test "stop: SIGTERM, cgroup removal, lazy-safe unmount and mount point removal":
        ops.stop(tester)
        check runtime.stopping(tester.uid)
        settle(proc(): bool = exits.len == 1)
        check exits == @[(true, false, int(SIGTERM))]
        check not dirExists(runtimeDir)
        check not isJumpstartRuntimeMount(readFile("/proc/self/mountinfo"), runtimeDir, tester.uid)
        if useCgroups: check not dirExists(usersRoot / $tester.uid)
        check runtime.userPid(tester.uid) == 0

      test "a pre-existing /run/user/UID that is not a Jumpstart mount fails the start":
        createDir(runtimeDir)
        writeFile(runtimeDir / "user-file", "x")
        check ops.start(tester, srFirstSession) == soFailed
        check fileExists(runtimeDir / "user-file")       # never touched
        check logs[^1].contains("not a Jumpstart runtime mount")
        removeDir(runtimeDir)

      test "a hand-started daemon holding the socket is reported, not counted":
        setMode("ok")
        let dir = home / ".local/share/jumpstart"
        createDir(dir)
        let listener = bindControlSocket(dir / "jumpstart.sock")
        for path in [home / ".local", home / ".local/share", dir, dir / "jumpstart.sock"]:
          discard posix.lchown(path.cstring, Uid(tester.uid), Gid(tester.gid))
        check ops.start(tester, srFirstSession) == soSocketInUse
        discard posix.close(listener)
        removeFile(dir / "jumpstart.sock")
        ops.stop(tester)                 # releases the runtime mount
        check not dirExists(runtimeDir)

      test "an unexpected exit is reported with its status and keeps the runtime mount":
        setMode("ok")
        exits.setLen(0)
        check ops.start(tester, srFirstSession) == soStarted
        discard posix.kill(Pid(runtime.userPid(tester.uid)), SIGKILL)
        settle(proc(): bool = exits.len == 1)
        check exits[0][0] == false          # not caused by the system
        check exits[0][1] == false          # socket not held by anyone
        check dirExists(runtimeDir)
        # A restart reuses the existing Jumpstart mount.
        removeFile(home / ".local/share/jumpstart/jumpstart.sock")
        check ops.start(tester, srUnexpectedExit) == soStarted
        ops.stop(tester)
        settle(proc(): bool = exits.len == 2)
        check not dirExists(runtimeDir)

      test "a daemon that never opens its socket fails after 10 seconds and is killed":
        setMode("nobind")
        let before = config.now()
        check ops.start(tester, srFirstSession) == soFailed
        check config.now() - before >= 10_000
        check runtime.userPid(tester.uid) == 0
        ops.stop(tester)
        check not dirExists(runtimeDir)
        removeFile(home / "mode")
