import std/[algorithm, options, os, sequtils, strutils, tables, unittest]
import posix
import jumpstartcore/[errors, reaper, sandbox, spawn]

proc exitnow(code: int) {.importc: "_exit", header: "<unistd.h>", noreturn.}

proc asTable(env: seq[EnvPair]): Table[string, string] =
  result = initTable[string, string]()
  for (key, value) in env: result[key] = value

proc readAll(fd: cint): string =
  var buffer: array[512, char]
  while true:
    let count = read(fd, addr buffer[0], buffer.len)
    if count > 0:
      for i in 0 ..< int(count): result.add(buffer[i])
    elif count < 0 and osLastError() == OSErrorCode(EINTR):
      continue
    else:
      break
  closeFd(fd)

proc reapEventually(r: Reaper, pid: Pid): ChildStatus =
  for unused in 0 .. 200:
    discard r.drain()
    if r.takeCompleted(pid, result): return
    sleep(5)
  raise newException(IOError, "child was not reaped")

suite "core spawn environment":
  test "system environment is closed, layered and duplicate-free":
    putEnv("JUMPSTART_PARENT_SECRET", "must-not-leak")
    let pairs = buildSystemEnvironment(
      manifest = {"PATH": "/manifest", "EXTRA": "yes", "EXTRA": "later"},
      jumpstart = {"JUMPSTART_CORE_NAME": "demo"})
    var keys: seq[string]
    for (key, _) in pairs: keys.add key
    check keys.deduplicate.len == keys.len
    let values = pairs.asTable
    check values.len == 4
    check values["LANG"] == "C.UTF-8"
    check values["PATH"] == "/manifest"
    check values["EXTRA"] == "later"
    check values["JUMPSTART_CORE_NAME"] == "demo"
    check not values.hasKey("JUMPSTART_PARENT_SECRET")

  test "manifest layer cannot set JUMPSTART variables":
    expect ValueError:
      discard buildSystemEnvironment(manifest = {"JUMPSTART_CORE_NAME": "wrong"})
    expect ValueError:
      discard buildSystemEnvironment(jumpstart = {"NOT_OURS": "x"})

suite "central reaper and fork exec":
  test "status decoding is portable":
    check decodeStatus(Pid(1), cint(7 shl 8)).kind == cekExited
    check decodeStatus(Pid(1), cint(7 shl 8)).code == 7
    check decodeStatus(Pid(1), cint(SIGTERM)).kind == cekSignaled
    check decodeStatus(Pid(1), cint(SIGTERM)).code == int(SIGTERM)

  test "spawn passes only explicit environment and central reaper owns status":
    let r = newReaper()
    var callbackStatus: ChildStatus
    var called = false
    let child = spawn(ProcessSpec(executable: "/usr/bin/env", workingDirectory: "/",
      environment: buildSystemEnvironment(manifest = {"ONLY_THIS": "present"})), r,
      owner = "test", callback = proc(status: ChildStatus) =
        called = true
        callbackStatus = status)
    closeFd(child.stderrFd)
    let output = readAll(child.stdoutFd)
    for unused in 0 .. 400:
      discard r.drain()
      if called: break
      sleep(5)
    let status = callbackStatus
    check called
    check callbackStatus.pid == child.pid
    check status.kind == cekExited
    check status.code == 0
    check output.contains("ONLY_THIS=present")
    check not output.contains("JUMPSTART_PARENT_SECRET")
    check r.registeredCount == 0

  test "protocol descriptors 3 and 4 are connected across exec":
    let r = newReaper()
    let child = spawn(ProcessSpec(executable: "/bin/sh",
      arguments: @["-c", """IFS= read -r value <&3; printf 'reply:%s' "$value" >&4"""],
      workingDirectory: "/", environment: buildSystemEnvironment(), protocol: true), r)
    let message = "hello\n"
    check write(child.protocolWriteFd, unsafeAddr message[0], message.len) == message.len
    closeFd(child.protocolWriteFd)
    let response = readAll(child.protocolReadFd)
    closeFd(child.stdoutFd); closeFd(child.stderrFd)
    check response == "reply:hello"
    check reapEventually(r, child.pid).code == 0

  test "child enters a new session and process group":
    let r = newReaper()
    let child = spawn(ProcessSpec(executable: "/bin/sleep", arguments: @["2"],
      workingDirectory: "/", environment: buildSystemEnvironment()), r)
    var group = Pid(-1)
    for unused in 0 .. 100:
      group = getpgid(child.pid)
      if group == child.pid: break
      sleep(2)
    check group == child.pid
    discard kill(-child.processGroup, SIGTERM)
    closeFd(child.stdoutFd); closeFd(child.stderrFd)
    let status = reapEventually(r, child.pid)
    check status.kind == cekSignaled
    check status.code == int(SIGTERM)

  test "cancellation escalates without blocking the event loop":
    let r = newReaper()
    let child = spawn(ProcessSpec(executable: "/bin/sleep", arguments: @["2"],
      workingDirectory: "/", environment: buildSystemEnvironment()), r)
    # Let the child pass the exec boundary before exercising group signals.
    sleep(20)
    var cancellation = beginCancellation(child.processGroup)
    check cancellation.stage == csTermSent
    check cancellation.advanceCancellation(cancellation.killAt)
    check cancellation.stage == csKillSent
    closeFd(child.stdoutFd); closeFd(child.stderrFd)
    discard reapEventually(r, child.pid)

  test "SIGCHLD handler only marks work for the event loop":
    let r = newReaper()
    installSigChldHandler(r)
    check r.wakeupFd >= 0
    discard posix.raise(SIGCHLD)
    check r.sigChldPending()
    discard r.drainWakeup()
    check not r.sigChldPending()
    r.close()

  test "Linux-only subreaper primitive is explicitly gated":
    when defined(linux):
      check compiles(enableChildSubreaper())
    else:
      expect OSError: enableChildSubreaper()

proc waitExit(r: Reaper; pid: Pid; status: var ChildStatus): bool =
  for unused in 0 .. 1000:
    discard r.drain()
    if r.takeCompleted(pid, status): return true
    sleep(5)

proc runCollect(spec: ProcessSpec): tuple[output: string; status: ChildStatus] =
  let r = newReaper()
  defer: r.close()
  let child = spawn(spec, r)
  closeFd(child.stderrFd)
  result.output = readAll(child.stdoutFd)
  if not waitExit(r, child.pid, result.status):
    raise newException(IOError, "child was not reaped")

proc tempRoot(name: string): string =
  result = getTempDir() / ("jumpstart-spawn-" & name & "-" & $getpid())
  if dirExists(result): removeDir(result)
  createDir(result)
  setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec})

proc writeScript(path, body: string; mode = 0o755) =
  writeFile(path, body)
  discard chmod(path.cstring, Mode(mode))

suite "verified executables":
  test "O_NOFOLLOW open and fstat re-check":
    let root = tempRoot("verify")
    defer: removeDir(root)
    createDir(root / "bin")
    writeScript(root / "bin" / "ok", "#!/bin/sh\necho ok\n")
    var verified = openVerifiedExecutable(root / "bin" / "ok", getuid(), beneath = root)
    check verified.fd >= 0
    check verified.script
    verified.close()
    createSymlink(root / "bin" / "ok", root / "bin" / "link")
    for bad in ["link"]:
      try:
        discard openVerifiedExecutable(root / "bin" / bad, getuid())
        check false
      except SpawnError as e:
        check e.code == ecPermission
    writeScript(root / "bin" / "groupwritable", "#!/bin/sh\n", 0o775)
    writeScript(root / "bin" / "noexec", "#!/bin/sh\n", 0o644)
    for bad in ["groupwritable", "noexec", "missing"]:
      try:
        discard openVerifiedExecutable(root / "bin" / bad, getuid())
        check false
      except SpawnError as e:
        check e.code == ecPermission
    # A symlinked directory below the core directory is rejected too.
    createSymlink(root / "bin", root / "linkdir")
    try:
      discard openVerifiedExecutable(root / "linkdir" / "ok", getuid(), beneath = root)
      check false
    except SpawnError as e:
      check e.code == ecPermission
    if getuid() != 0:
      try:
        discard openVerifiedExecutable(root / "bin" / "ok", Uid(getuid() + 1))
        check false
      except SpawnError as e:
        check e.code == ecPermission

  test "scripts and binaries execute through the verified descriptor":
    let root = tempRoot("execfd")
    defer: removeDir(root)
    writeScript(root / "tool", "#!/bin/sh\nprintf 'script:%s' \"$1\"\n")
    var verified = openVerifiedExecutable(root / "tool", getuid())
    defer: verified.close()
    let ran = runCollect(ProcessSpec(executable: root / "tool", executableFd: some(verified.fd),
      arguments: @["arg one"], workingDirectory: "/", environment: buildSystemEnvironment()))
    check ran.output == "script:arg one"
    check ran.status.code == 0
    var env = openVerifiedExecutable("/usr/bin/env", getuid())
    defer: env.close()
    check not env.script
    let listed = runCollect(ProcessSpec(executable: "/usr/bin/env", executableFd: some(env.fd),
      workingDirectory: "/", environment: @[("ONLY", "this")]))
    check listed.output.strip == "ONLY=this"

  when defined(linux):
    test "a script runs through the verified descriptor when /dev has no fd symlink":
      # Stock initramfs: /dev is a bare devtmpfs, so the kernel's /dev/fd/5
      # interpreter path does not exist. Needs root and a private mount
      # namespace (done in a forked child); skipped otherwise.
      if getuid() != 0: skip()
      let root = tempRoot("nodevfd")
      defer: removeDir(root)
      writeScript(root / "tool", "#!/bin/sh\nprintf 'script:%s' \"$1\"\n")
      proc unshareNs(flags: cint): cint {.importc: "unshare", header: "<sched.h>".}
      proc mountFs(source, target, fstype: cstring; flags: culong; data: pointer): cint
        {.importc: "mount", header: "<sys/mount.h>".}
      proc makeDev(path: cstring; mode: Mode; dev: culong): cint
        {.importc: "mknod", header: "<sys/stat.h>".}
      let pid = fork()
      check pid >= 0
      if pid == 0:
        var code = 10
        try:
          if unshareNs(0x00020000) == 0 and                       # CLONE_NEWNS
              mountFs("none", "/", nil, culong(0x4000 or 0x40000), nil) == 0 and  # MS_REC|MS_PRIVATE
              mountFs("tmpfs", "/dev", "tmpfs", 0, nil) == 0 and
              makeDev("/dev/null", Mode(0o20666), culong((1 shl 8) or 3)) == 0:
            code = 11
            var verified = openVerifiedExecutable(root / "tool", getuid())
            let ran = runCollect(ProcessSpec(executable: root / "tool",
              executableFd: some(verified.fd), arguments: @["arg"],
              workingDirectory: "/", environment: buildSystemEnvironment()))
            verified.close()
            writeFile(root / "out", ran.output)
            code = if ran.status.code == 0: 0 else: 12
        except CatchableError:
          discard
        exitnow(code)
      var status: cint
      discard waitpid(pid, status, 0)
      if status == 10 shl 8: skip()    # no mount namespace here
      check status == 0
      check readFile(root / "out") == "script:arg"

  test "a replaced executable never runs the replacement":
    let root = tempRoot("swap")
    defer: removeDir(root)
    writeScript(root / "tool", "#!/bin/sh\necho original\n")
    var verified = openVerifiedExecutable(root / "tool", getuid())
    defer: verified.close()
    writeScript(root / "replacement", "#!/bin/sh\necho replaced\n")
    moveFile(root / "replacement", root / "tool")
    let spec = ProcessSpec(executable: root / "tool", executableFd: some(verified.fd),
      workingDirectory: "/", environment: buildSystemEnvironment())
    when defined(linux):
      check runCollect(spec).output.strip == "original"
    else:
      try:
        discard runCollect(spec)
        check false
      except SpawnError as e:
        check e.code == ecPermission
        check e.stage == ssExec

suite "child setup failures are reported, never executed":
  test "working directory and exec failures":
    try:
      discard runCollect(ProcessSpec(executable: "/bin/sh", workingDirectory: "/nonexistent-jumpstart",
        environment: buildSystemEnvironment()))
      check false
    except SpawnError as e:
      check e.stage == ssWorkingDirectory
      check e.code == ecIo
    try:
      discard runCollect(ProcessSpec(executable: "/nonexistent-jumpstart-binary",
        workingDirectory: "/", environment: buildSystemEnvironment()))
      check false
    except SpawnError as e:
      check e.stage == ssExec
      check e.code == ecBackend

  test "cgroup join failure is E_CGROUP and leaves nothing registered":
    let r = newReaper()
    defer: r.close()
    try:
      discard spawn(ProcessSpec(executable: "/bin/sh", workingDirectory: "/",
        environment: buildSystemEnvironment(),
        cgroupProcs: getTempDir() / "no-such-cgroup" / "cgroup.procs"), r)
      check false
    except SpawnError as e:
      check e.code == ecCgroup
    check r.registeredCount == 0

  test "missing accounts and refused credential changes are E_PERMISSION":
    try:
      discard resolveIdentity("jumpstart-no-such-account")
      check false
    except SpawnError as e:
      check e.code == ecPermission
    if getuid() != 0:
      var spec = ProcessSpec(executable: "/usr/bin/id", workingDirectory: "/",
        environment: buildSystemEnvironment())
      spec.applyIdentity(ProcessIdentity(user: "other", uid: Uid(getuid() + 1),
        gid: getgid(), groups: @[getgid()]))
      try:
        discard runCollect(spec)
        check false
      except SpawnError as e:
        check e.stage == ssIdentity
        check e.code == ecPermission

  test "credentials are dropped to the account with its groups (root only)":
    if getuid() == 0:
      let identity = resolveIdentity("nobody")
      var spec = ProcessSpec(executable: "/bin/sh", arguments: @["-c", "id -u; id -g; id -G"],
        workingDirectory: "/", environment: buildSystemEnvironment())
      spec.applyIdentity(identity)
      let lines = runCollect(spec).output.strip.splitLines
      check lines[0] == $identity.uid
      check lines[1] == $identity.gid
      var groups: seq[string]
      for g in identity.groups: groups.add $g
      check lines[2].splitWhitespace.sorted == groups.sorted
    else:
      skip()

suite "process attributes":
  test "signal dispositions are reset and stray descriptors are closed":
    let previous = signal(SIGTERM, SIG_IGN)
    defer: discard signal(SIGTERM, previous)
    let leaked = dup2(0, 37)
    check leaked == 37
    discard fcntl(37, F_SETFD, 0)
    defer: discard close(37)
    let ran = runCollect(ProcessSpec(executable: "/bin/sh",
      arguments: @["-c", "if [ -e /dev/fd/37 ]; then echo leaked; else echo clean; fi; kill -TERM $$; echo survived"],
      workingDirectory: "/", environment: buildSystemEnvironment()))
    check ran.output.strip == "clean"
    check ran.status.kind == cekSignaled
    check ran.status.code == int(SIGTERM)

suite "native unit standard descriptors":
  test "nullStdio puts 0-2 on /dev/null without pipes":
    let r = newReaper()
    let child = spawn(ProcessSpec(executable: "/bin/sh",
      arguments: @["-c", "[ /dev/fd/0 -ef /dev/null ] && [ /dev/fd/1 -ef /dev/null ] && " &
        "[ /dev/fd/2 -ef /dev/null ] && echo discarded && echo discarded >&2"],
      workingDirectory: "/", environment: buildSystemEnvironment(), nullStdio: true), r)
    check child.stdoutFd == -1
    check child.stderrFd == -1
    check child.processGroup == child.pid
    let status = reapEventually(r, child.pid)
    check status.kind == cekExited
    check status.code == 0
    check r.registeredCount == 0

  test "inheritStdio with keepSession shares the caller's descriptors and group":
    let r = newReaper()
    var output: array[2, cint]
    check pipe(output) == 0
    for fd in output: discard fcntl(fd, F_SETFD, FD_CLOEXEC)
    let saved = dup(STDOUT_FILENO)
    check saved >= 0
    discard dup2(output[1], STDOUT_FILENO)
    var child: SpawnedProcess
    try:
      child = spawn(ProcessSpec(executable: "/bin/sh",
        arguments: @["-c", "echo inherited; sleep 1"], workingDirectory: "/",
        environment: buildSystemEnvironment(), keepSession: true,
        inheritStdio: true), r)
    finally:
      discard dup2(saved, STDOUT_FILENO)
      discard close(saved)
      discard close(output[1])
    check child.stdoutFd == -1
    check child.stderrFd == -1
    check child.processGroup == getpgrp()
    check getpgid(child.pid) == getpgrp()
    check readAll(output[0]).strip == "inherited"
    check reapEventually(r, child.pid).code == 0

  test "nullStdio and inheritStdio are exclusive":
    expect ValueError:
      discard spawn(ProcessSpec(executable: "/bin/true", workingDirectory: "/",
        nullStdio: true, inheritStdio: true), newReaper())

suite "sandbox in the spawn layer":
  test "unavailable sandbox fails closed before anything runs":
    when not defined(linux):
      let root = tempRoot("nosandbox")
      defer: removeDir(root)
      expect SandboxError:
        discard prepareSandbox(SandboxConfig(stateDir: root, workingDirectory: root))
    else:
      skip()

  test "sandbox properties are applied (Linux; user namespace when not root)":
    when defined(linux):
      if not sandboxSupported():
        skip()
      else:
        let root = tempRoot("sandbox")
        defer: removeDir(root)
        createDir(root / "state"); createDir(root / "extra")
        writeFile("/tmp/jumpstart-host-marker-" & $getpid(), "host")
        defer: removeFile("/tmp/jumpstart-host-marker-" & $getpid())
        let prepared = prepareSandbox(SandboxConfig(stateDir: root / "state",
          writablePaths: @[root / "extra"], workingDirectory: root / "state"))
        let script = """
echo pid=$$
touch /jumpstart-root-write 2>/dev/null && echo root=writable || echo root=readonly
touch state-file && echo state=writable || echo state=readonly
touch """ & root & """/extra/x && echo extra=writable || echo extra=readonly
touch /tmp/private && echo tmp=writable || echo tmp=readonly
test -e /tmp/jumpstart-host-marker-""" & $getpid() & """ && echo tmp=shared || echo tmp=private
echo net=$(sed -n '3,$p' /proc/net/dev | cut -d: -f1 | tr -d ' ' | tr '\n' ' ')
grep -E '^(CapEff|CapPrm|CapBnd|CapAmb|NoNewPrivs|Seccomp):' /proc/self/status | tr -s '\t ' ' '
"""
        var ran: tuple[output: string; status: ChildStatus]
        var unavailable = false
        try:
          ran = runCollect(ProcessSpec(executable: "/bin/sh", arguments: @["-c", script],
            workingDirectory: root / "state", environment: buildSystemEnvironment(),
            sandbox: some(prepared)))
        except SpawnError as e:
          # Some hosts forbid unprivileged user namespaces (§7.4 item 10):
          # the only acceptable outcome then is E_SANDBOX.
          check getuid() != 0
          check e.code == ecSandbox
          checkpoint("unprivileged user namespaces unavailable: " & e.msg)
          unavailable = true
        if unavailable: skip()
        else:
          let output = ran.output
          check ran.status.code == 0
          check "pid=2" in output
          check "root=readonly" in output
          check "state=writable" in output
          check "extra=writable" in output
          check "tmp=writable" in output
          check "tmp=private" in output
          check "CapEff: 0000000000000000" in output
          check "CapPrm: 0000000000000000" in output
          check "CapBnd: 0000000000000000" in output
          check "CapAmb: 0000000000000000" in output
          check "NoNewPrivs: 1" in output
          check "Seccomp: 2" in output
          check not fileExists("/jumpstart-root-write")
          check fileExists(root / "state" / "state-file")
          check "net=lo\n" in output
    else:
      skip()

  test "sandbox application failure is E_SANDBOX and the program never runs":
    when defined(linux):
      if not sandboxSupported():
        skip()
      else:
        let root = tempRoot("sandboxfail")
        defer: removeDir(root)
        createDir(root / "state"); createDir(root / "gone")
        let prepared = prepareSandbox(SandboxConfig(stateDir: root / "state",
          writablePaths: @[root / "gone"], workingDirectory: root / "state"))
        removeDir(root / "gone") # disappears between dispatch and application
        try:
          discard runCollect(ProcessSpec(executable: "/bin/sh",
            arguments: @["-c", "touch " & root & "/state/ran"],
            workingDirectory: root / "state", environment: buildSystemEnvironment(),
            sandbox: some(prepared)))
          check false
        except SpawnError as e:
          check e.code == ecSandbox
          check e.stage == ssSandbox
        check not fileExists(root / "state" / "ran")
    else:
      skip()
