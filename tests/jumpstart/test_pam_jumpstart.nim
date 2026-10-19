import std/[json, net, os, osproc, posix, sequtils, strutils, unittest]
import ../../jumpstart/pam_jumpstart


proc cExit(code: cint) {.importc: "_exit", header: "<unistd.h>".}

proc pamClientChild(path, request: string) =
  ## Real production helper under test, run in a forked child so the parent
  ## can own the listening server. Exits without running Nim cleanup.
  let ok = sendToSystemSocket(request, path)
  cExit(if ok: 0 else: 7)

suite "PAM Jumpstart request helpers":
  test "constructs open and close requests with exact inputs":
    for (action, expected) in [(sessionOpen, "open"), (sessionClose, "close")]:
      let line = buildSessionRequest(action, 1000'u32, "opaque\nidentifier")
      check line.endsWith("\n")
      let node = parseJson(line)
      check node["client"]["name"].getStr == "pam_jumpstart"
      check node["client"]["version"].getStr.len > 0
      check node["session"]["action"].getStr == expected
      check node["session"]["uid"].getInt == 1000
      check node["session"]["id"].getStr == "opaque\nidentifier"

  test "session identifier is stable for one PAM transaction":
    check buildSessionId(0x1234'u, 55) == buildSessionId(0x1234'u, 55)
    check buildSessionId(0x1234'u, 55) != buildSessionId(0x1235'u, 55)
    check buildSessionId(0x1234'u, 55) != buildSessionId(0x1234'u, 56)

  test "empty identifiers are rejected":
    expect ValueError:
      discard buildSessionRequest(sessionOpen, 1000, "")

  test "response validation accepts only successful response envelopes":
    check responseIsSuccess("""{"type":"response","status":"ok","result":{},"warnings":[]}""")
    check not responseIsSuccess("""{"type":"response","status":"error"}""")
    check not responseIsSuccess("not json")

  test "notification passes the request to an injected transport":
    var captured = ""
    check notifySession(sessionClose, 42, "s1", proc(line: string): bool =
      captured = line
      true)
    check parseJson(captured)["session"]["uid"].getInt == 42

  test "notification is fail-open safe":
    check not notifySession(sessionOpen, 42, "s1", nil)
    check not notifySession(sessionOpen, 42, "s1", proc(line: string): bool =
      raise newException(IOError, "socket unavailable"))


  test "system-socket transport performs one real Unix request":
    let root = getTempDir() / ("pam-jumpstart-" & $getCurrentProcessId())
    removeDir(root)
    createDir(root)
    defer: removeDir(root)
    let path = root / "jumpstart.sock"
    let expected = buildSessionRequest(sessionOpen, 1234, "real-socket")
    var listener = newSocket(Domain(AF_UNIX), SockType(SOCK_STREAM), Protocol(IPPROTO_IP))
    defer: listener.close()
    listener.bindUnix(path)
    listener.listen()
    let pid = fork()
    if pid == 0:
      pamClientChild(path, expected)
    var client: owned(Socket)
    listener.accept(client)
    var request = ""
    client.readLine(request, maxLength = MaxPamResponseBytes)
    client.send("""{"type":"response","status":"ok","result":{},"warnings":[]}""" & "\n")
    client.close()
    var status: cint
    discard waitpid(pid, status, 0)
    check WIFEXITED(status)
    check WEXITSTATUS(status) == 0
    check request == expected.strip(leading = false, trailing = true,
      chars = {'\r', '\n'})

proc serveOnce(path: string; reply: string; delayMs: int): Pid =
  ## Forked one-connection server: reads the request line, then after
  ## `delayMs` sends `reply` (nothing when empty) and exits.
  var listener = newSocket(Domain(AF_UNIX), SockType(SOCK_STREAM), Protocol(IPPROTO_IP))
  listener.bindUnix(path)
  listener.listen()
  result = fork()
  if result == 0:
    var client: owned(Socket)
    listener.accept(client)
    var line = ""
    client.readLine(line, maxLength = MaxPamResponseBytes)
    if delayMs > 0: sleep(delayMs)
    if reply.len > 0: client.send(reply)
    client.close()
    cExit(0)
  listener.close()

proc monoMs(): int64 =
  var ts: Timespec
  discard clock_gettime(CLOCK_MONOTONIC, ts)
  int64(ts.tv_sec) * 1000 + int64(ts.tv_nsec) div 1_000_000

suite "PAM session identifiers and transport":
  test "open creates and stores a fresh identifier; close reuses the stored one":
    var made = 0
    let fresh = proc(): string =
      inc made
      buildSessionId(0x10'u, 7, uint64(made))
    let opened = sessionIdFor(sessionOpen, "", fresh)
    check opened.store and opened.id == "pam-" & toHex(0x10'u) & "-7-" & toHex(1'u64)
    check sessionIdFor(sessionOpen, opened.id, fresh).id != opened.id
    let closed = sessionIdFor(sessionClose, opened.id, fresh)
    check closed == (opened.id, false)
    check sessionIdFor(sessionClose, "", fresh) == ("", false)   # never opened
    check randomNonce() != randomNonce()

  test "the module waits longer for an answer than the daemon waits for the user socket":
    check ResponseTimeoutMs > DaemonSocketWaitMs

  test "a missing socket fails with a reason":
    var detail = ""
    check not sendToSystemSocketDetailed("{}\n", getTempDir() / "pam-none.sock", detail)
    check detail.startsWith("connect ")

  test "a silent daemon times out; a slow answer inside the limit is accepted":
    let root = getTempDir() / ("pam-timeout-" & $getCurrentProcessId())
    removeDir(root)
    createDir(root)
    defer: removeDir(root)
    let ok = """{"type":"response","status":"ok","result":{},"warnings":[]}""" & "\n"
    var detail = ""
    var status: cint
    var pid = serveOnce(root / "a.sock", "", 1500)
    let before = monoMs()
    check not sendToSystemSocketDetailed("{}\n", root / "a.sock", detail, timeoutMs = 300)
    check monoMs() - before >= 300 and monoMs() - before < 1500
    check detail.startsWith("no response")
    discard waitpid(pid, status, 0)
    pid = serveOnce(root / "b.sock", ok, 500)
    check sendToSystemSocketDetailed("{}\n", root / "b.sock", detail, timeoutMs = 3000)
    discard waitpid(pid, status, 0)
    pid = serveOnce(root / "c.sock", "", 0)
    check not sendToSystemSocketDetailed("{}\n", root / "c.sock", detail)
    check detail == "connection closed without a response"
    discard waitpid(pid, status, 0)
    pid = serveOnce(root / "d.sock", """{"type":"response","status":"error"}""" & "\n", 0)
    check not sendToSystemSocketDetailed("{}\n", root / "d.sock", detail)
    check detail.startsWith("response rejected")
    discard waitpid(pid, status, 0)

  test "a daemon that hangs up mid-request does not raise SIGPIPE in the login process":
    let root = getTempDir() / ("pam-pipe-" & $getCurrentProcessId())
    removeDir(root)
    createDir(root)
    defer: removeDir(root)
    var listener = newSocket(Domain(AF_UNIX), SockType(SOCK_STREAM), Protocol(IPPROTO_IP))
    listener.bindUnix(root / "p.sock")
    listener.listen()
    let pid = fork()
    if pid == 0:
      var client: owned(Socket)
      listener.accept(client)
      client.close()
      cExit(0)
    var detail = ""
    let big = repeat('x', 8 * 1024 * 1024) & "\n"   # far larger than the socket buffer
    check not sendToSystemSocketDetailed(big, root / "p.sock", detail)
    check detail.len > 0
    var status: cint
    discard waitpid(pid, status, 0)
    listener.close()

const PamHarness = """
#define _GNU_SOURCE
#include <sched.h>
#include <security/pam_appl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>
static int conv(int n, const struct pam_message **m, struct pam_response **r, void *d) { return PAM_CONV_ERR; }
static pid_t server = 0;
static void serve(const char *log, const char *reply) {
  struct sockaddr_un a; memset(&a, 0, sizeof a); a.sun_family = AF_UNIX;
  strcpy(a.sun_path, "/run/jumpstart.sock");
  int s = socket(AF_UNIX, SOCK_STREAM, 0);
  if (bind(s, (struct sockaddr *)&a, sizeof a) || listen(s, 8)) _exit(70);
  if ((server = fork()) != 0) { close(s); return; }
  for (;;) {
    int c = accept(s, NULL, NULL); char buf[4096]; int n = 0, k;
    while (n < (int)sizeof buf - 1 && (k = read(c, buf + n, sizeof buf - 1 - n)) > 0) {
      n += k; if (memchr(buf, '\n', n)) break;
    }
    buf[n] = 0;
    FILE *f = fopen(log, "a"); fputs(buf, f); fclose(f);
    write(c, reply, strlen(reply)); write(c, "\n", 1); close(c);
  }
}
static int session(const char *confdir, const char *user, int forkedClose) {
  struct pam_conv cv = {conv, NULL}; pam_handle_t *h;
  if (pam_start_confdir("jumpstart-test", user, &cv, confdir, &h) != PAM_SUCCESS) return 71;
  int open = pam_open_session(h, 0), close = PAM_SUCCESS;
  if (forkedClose) {
    pid_t p = fork();
    if (p == 0) _exit(pam_close_session(h, 0));
    int st; waitpid(p, &st, 0); close = WIFEXITED(st) ? WEXITSTATUS(st) : 72;
  } else close = pam_close_session(h, 0);
  pam_end(h, PAM_SUCCESS);
  printf("%d %d\n", open, close);
  return 0;
}
int main(int argc, char **argv) {
  /* argv: confdir log user mode(ok|error|none) */
  if (unshare(CLONE_NEWNS) || mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL) ||
      mount("tmpfs", "/run", "tmpfs", 0, "mode=0755")) return 77;
  signal(SIGCHLD, SIG_DFL);
  if (strcmp(argv[4], "none") != 0)
    serve(argv[2], strcmp(argv[4], "ok") == 0
      ? "{\"type\":\"response\",\"status\":\"ok\",\"result\":{},\"warnings\":[]}"
      : "{\"type\":\"response\",\"status\":\"error\",\"error\":{\"code\":\"E_BACKEND\",\"message\":\"x\"}}");
  int rc = session(argv[1], argv[3], 1);
  if (rc == 0) rc = session(argv[1], argv[3], 0);
  if (server > 0) { kill(server, SIGKILL); waitpid(server, NULL, 0); }
  return rc;
}
"""

proc pamHarnessAvailable(): bool =
  when not defined(linux): false
  else:
    getuid() == 0 and findExe("gcc").len > 0 and findExe("nim").len > 0 and
      getpwnam("nobody") != nil and
      fileExists("/usr/include/security/pam_appl.h") and
      "pam_start_confdir" in readFile("/usr/include/security/pam_appl.h")

suite "pam_jumpstart.so in a real PAM stack":
  if not pamHarnessAvailable():
    test "PAM stack tests skipped (need Linux, root, gcc, nim and Linux-PAM >= 1.4 headers)":
      skip()
  else:
    let root = getTempDir() / ("pam-stack-" & $getCurrentProcessId())
    removeDir(root)
    createDir(root / "conf")
    let module = root / "pam_jumpstart.so"
    let source = currentSourcePath().parentDir.parentDir.parentDir / "jumpstart" / "pam_jumpstart.nim"
    doAssert execShellCmd("nim c --app:lib --noMain:on -d:pamJumpstartModule --hints:off " &
      "--nimcache:" & root / "cache" & " -o:" & module & " " & source & " > " & root / "build.log 2>&1") == 0
    writeFile(root / "harness.c", PamHarness)
    doAssert execShellCmd("gcc -o " & root / "harness " & root / "harness.c -lpam") == 0
    writeFile(root / "conf" / "jumpstart-test", "session required " & module & "\n")
    let nobody = getpwnam("nobody").pw_uid

    proc run(mode: string): tuple[output: string, code: int, log: seq[JsonNode]] =
      let log = root / ("log-" & mode)
      removeFile(log)
      let (output, code) = execCmdEx(root / "harness " & root / "conf " & log & " nobody " & mode)
      result.output = output
      result.code = code
      if fileExists(log):
        for line in readFile(log).splitLines:
          if line.len > 0: result.log.add parseJson(line)

    test "open and close reach the daemon with one identifier per transaction":
      let r = run("ok")
      if r.code == 77:
        skip()
      else:
        check r.code == 0
        check r.output == "0 0\n0 0\n"
        check r.log.len == 4
        if r.log.len == 4:
          check r.log.mapIt(it["session"]["action"].getStr) == @["open", "close", "open", "close"]
          for entry in r.log:
            check entry["client"]["name"].getStr == PamClientName
            check entry["session"]["uid"].getInt == int(nobody)
          # The first close ran in a forked child: same identifier anyway.
          check r.log[0]["session"]["id"] == r.log[1]["session"]["id"]
          check r.log[2]["session"]["id"] == r.log[3]["session"]["id"]
          check r.log[0]["session"]["id"] != r.log[2]["session"]["id"]

    test "a refusing or absent daemon never fails the login":
      for mode in ["error", "none"]:
        let r = run(mode)
        if r.code == 77:
          skip()
        else:
          check r.code == 0
          check r.output == "0 0\n0 0\n"
          check r.log.len == (if mode == "none": 0 else: 4)

    removeDir(root)
