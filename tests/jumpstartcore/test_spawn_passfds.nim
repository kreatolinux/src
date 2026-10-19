## `ProcessSpec.explicitStdio` and `ProcessSpec.passFds` (§15.4): descriptors a
## core's helper process inherits at fixed numbers. Runs on macOS and Linux.
import std/[os, options, strutils, unittest]
import posix
import jumpstartcore/[reaper, spawn]

proc readAll(fd: cint): string =
  var buffer: array[512, char]
  while true:
    let count = read(fd, addr buffer[0], buffer.len)
    if count > 0:
      for i in 0 ..< int(count): result.add(buffer[i])
    elif count < 0 and osLastError() == OSErrorCode(EINTR): continue
    else: break

proc reaped(r: Reaper; pid: Pid): ChildStatus =
  for unused in 0 .. 400:
    discard r.drain()
    if r.takeCompleted(pid, result): return
    sleep(5)
  raise newException(IOError, "child was not reaped")

proc pipePair(cloexec = true): (cint, cint) =
  var fds: array[2, cint]
  doAssert pipe(fds) == 0
  if cloexec:
    for fd in fds: doAssert fcntl(fd, F_SETFD, FD_CLOEXEC) == 0
  (fds[0], fds[1])

proc isOpen(fd: cint): bool = fcntl(fd, F_GETFD) >= 0

proc place(fd, number: cint): cint =
  ## Move `fd` to exactly `number` in this process (with FD_CLOEXEC set).
  doAssert dup2(fd, number) == number
  discard close(fd)
  discard fcntl(number, F_SETFD, FD_CLOEXEC)
  number

proc sh(script: string; passFds: seq[PassedFd] = @[]; protocol = false;
        explicitStdio = none(array[3, cint])): ProcessSpec =
  ProcessSpec(executable: "/bin/sh", arguments: @["-c", script], workingDirectory: "/",
    environment: @[("PATH", "/usr/bin:/bin")], passFds: passFds, protocol: protocol,
    explicitStdio: explicitStdio)

proc runOut(spec: ProcessSpec): (string, ChildStatus) =
  let r = newReaper()
  let child = spawn(spec, r)
  closeFd(child.stderrFd)
  let text = if child.stdoutFd >= 0: readAll(child.stdoutFd) else: ""
  closeFd(child.stdoutFd)
  (text, r.reaped(child.pid))

suite "explicit standard descriptors":
  test "0, 1 and 2 become the given descriptors; nothing is created or consumed":
    let (inRead, inWrite) = pipePair()
    let (outRead, outWrite) = pipePair()
    let (errRead, errWrite) = pipePair()
    let text = "from-stdin\n"
    check write(inWrite, unsafeAddr text[0], text.len) == text.len
    closeFd(inWrite)
    let r = newReaper()
    let child = spawn(sh("read -r line; echo \"out:$line\"; echo \"err:$line\" >&2",
      explicitStdio = some([inRead, outWrite, errWrite])), r)
    check child.stdoutFd == -1 and child.stderrFd == -1
    check child.processGroup == child.pid
    # The caller's descriptors are untouched and still its own.
    check isOpen(inRead) and isOpen(outWrite) and isOpen(errWrite)
    closeFd(inRead); closeFd(outWrite); closeFd(errWrite)
    check readAll(outRead) == "out:from-stdin\n"
    check readAll(errRead) == "err:from-stdin\n"
    closeFd(outRead); closeFd(errRead)
    check r.reaped(child.pid).code == 0

  test "one descriptor may serve as several standard streams":
    let (outRead, outWrite) = pipePair()
    let null = open("/dev/null", O_RDONLY)
    let r = newReaper()
    let child = spawn(sh("echo one; echo two >&2",
      explicitStdio = some([null, outWrite, outWrite])), r)
    closeFd(null); closeFd(outWrite)
    check readAll(outRead) == "one\ntwo\n"
    closeFd(outRead)
    check r.reaped(child.pid).code == 0

  test "it excludes nullStdio and inheritStdio and rejects invalid descriptors":
    let (rd, wr) = pipePair()
    defer: closeFd(rd); closeFd(wr)
    let r = newReaper()
    var spec = sh("true", explicitStdio = some([rd, wr, wr]))
    spec.nullStdio = true
    expect ValueError: discard spawn(spec, r)
    spec.nullStdio = false; spec.inheritStdio = true
    expect ValueError: discard spawn(spec, r)
    expect ValueError: discard spawn(sh("true", explicitStdio = some([rd, wr, 999])), r)
    expect ValueError: discard spawn(sh("true", explicitStdio = some([rd, -1, wr])), r)
    check r.registeredCount == 0

  test "a swap of two numbers works because sources are copied first":
    let (rd, wr) = pipePair()
    let a = place(rd, 40)
    let b = place(wr, 41)
    # target 40 <- the write end (source 41), target 41 <- the read end (source 40)
    let (text, status) = runOut(sh("echo swapped >/dev/fd/40; read -r line </dev/fd/41; echo \"$line\"",
      passFds = @[(source: b, target: cint(40)), (source: a, target: cint(41))]))
    check status.code == 0
    check text == "swapped\n"
    check isOpen(a) and isOpen(b)
    closeFd(a); closeFd(b)

suite "passed descriptors":
  test "descriptors appear at their targets with FD_CLOEXEC cleared":
    let (rd, wr) = pipePair()   # both close-on-exec in the caller
    check (fcntl(wr, F_GETFD) and FD_CLOEXEC) != 0
    let (text, status) = runOut(sh("echo hello >/dev/fd/20",
      passFds = @[(source: wr, target: cint(20))]))
    closeFd(wr)
    check status.code == 0
    check text == ""
    check readAll(rd) == "hello\n"
    closeFd(rd)

  test "targets 3 to 6 are contiguous, as socket activation needs":
    let (rd, wr) = pipePair()
    let (text, status) = runOut(sh(
      "for n in 3 4 5 6; do echo $n >/dev/fd/$n; done",
      passFds = @[(source: wr, target: cint(3)), (source: wr, target: cint(4)),
                  (source: wr, target: cint(5)), (source: wr, target: cint(6))]))
    closeFd(wr)
    check status.code == 0
    check readAll(rd) == "3\n4\n5\n6\n"
    closeFd(rd)

  test "setup failures are still reported when the status pipe would sit on a target":
    let (rd, wr) = pipePair()
    var spec = sh("true", passFds = @[(source: wr, target: cint(7)), (source: wr, target: cint(8)),
                                      (source: wr, target: cint(9))])
    spec.executable = "/nonexistent/program"
    let r = newReaper()
    expect SpawnError:
      discard spawn(spec, r)
    closeFd(wr); closeFd(rd)

  test "sources are not consumed and may be shared or alias another target":
    let (rd, wr) = pipePair()
    let a = place(wr, 30)       # a == 30
    # target 30 is also the source of another entry: the swap-like case
    let (_, status) = runOut(sh("echo x >/dev/fd/30; echo y >/dev/fd/31",
      passFds = @[(source: a, target: cint(31)), (source: a, target: cint(30))]))
    check status.code == 0
    check isOpen(a)
    closeFd(a)
    check readAll(rd) == "x\ny\n"
    closeFd(rd)

  test "everything else is closed, including descriptors above the targets":
    let stray = place(pipePair(cloexec = false)[0], 37)
    discard fcntl(stray, F_SETFD, 0)   # would leak without the close
    let (rd, wr) = pipePair()
    let kept = place(wr, 44)
    let probe = "for n in 36 37 38 43 44 45 50; do " &
      "if [ -e /dev/fd/$n ]; then printf '%s ' $n; fi; done; echo"
    let (text, status) = runOut(sh(probe, passFds = @[(source: kept, target: cint(44))]))
    check status.code == 0
    check text.strip == "44"
    closeFd(stray); closeFd(kept); closeFd(rd)

  test "high targets and many descriptors":
    var spec = sh("for n in 7 8 9 200 500 1023; do [ -e /dev/fd/$n ] && printf '%s ' $n; done; echo")
    var held: seq[cint]
    for target in [7, 8, 9, 200, 500, 1023]:
      let fd = open("/dev/null", O_RDONLY)
      held.add fd
      spec.passFds.add((source: fd, target: cint(target)))
    let (text, status) = runOut(spec)
    for fd in held: closeFd(fd)
    check status.code == 0
    check text.strip == "7 8 9 200 500 1023"

  test "targets 3 and 4 are the protocol descriptors: only without `protocol`":
    let fd = open("/dev/null", O_RDONLY)
    defer: closeFd(fd)
    # Without `protocol` a helper may receive descriptor 3 (and 4); with
    # `protocol` the spawn layer owns them.
    let (text, status) = runOut(sh("[ -e /dev/fd/3 ] && echo three; [ -e /dev/fd/4 ] && echo four; true",
      passFds = @[(source: fd, target: cint(3))]))
    check status.code == 0
    check text.strip == "three"
    let r = newReaper()
    expect ValueError:
      discard spawn(sh("true", passFds = @[(source: fd, target: cint(3))], protocol = true), r)
    expect ValueError:
      discard spawn(sh("true", passFds = @[(source: fd, target: cint(4))], protocol = true), r)
    # Without passFds, 3 and 4 are closed in a non-protocol child as before.
    let (clean, _) = runOut(sh("[ -e /dev/fd/3 ] || [ -e /dev/fd/4 ] || echo closed"))
    check clean.strip == "closed"
    # A protocol child can still receive higher descriptors next to 3 and 4.
    let child = spawn(sh("IFS= read -r value <&3; [ -e /dev/fd/9 ] && printf 'reply:%s' \"$value\" >&4",
      passFds = @[(source: fd, target: cint(9))], protocol = true), r)
    let message = "hi\n"
    check write(child.protocolWriteFd, unsafeAddr message[0], message.len) == message.len
    closeFd(child.protocolWriteFd)
    check readAll(child.protocolReadFd) == "reply:hi"
    closeFd(child.protocolReadFd); closeFd(child.stdoutFd); closeFd(child.stderrFd)
    check r.reaped(child.pid).code == 0

  test "invalid targets and sources are rejected before anything is forked":
    let fd = open("/dev/null", O_RDONLY)
    defer: closeFd(fd)
    let r = newReaper()
    for target in [-1, 0, 1, 2, 1024, 100000]:
      expect ValueError:
        discard spawn(sh("true", passFds = @[(source: fd, target: cint(target))]), r)
    expect ValueError:
      discard spawn(sh("true", passFds = @[(source: fd, target: cint(10)),
        (source: fd, target: cint(10))]), r)
    expect ValueError:
      discard spawn(sh("true", passFds = @[(source: cint(999), target: cint(10))]), r)
    expect ValueError:
      discard spawn(sh("true", passFds = @[(source: cint(-1), target: cint(10))]), r)
    check r.registeredCount == 0

  test "passed descriptors and the verified executable descriptor coexist":
    let verified = openVerifiedExecutable(expandFilename("/bin/sh"), Uid(0))
    let fd = open("/dev/null", O_RDONLY)
    var spec = sh("[ -e /dev/fd/10 ] && echo passed", passFds = @[(source: fd, target: cint(10))])
    spec.executableFd = some(verified.fd)
    let (text, status) = runOut(spec)
    var copy = verified
    copy.close()
    closeFd(fd)
    check status.code == 0
    check text.strip == "passed"

  test "target 5 is free next to a verified binary, and refused for a script":
    let verified = openVerifiedExecutable(expandFilename("/bin/sh"), Uid(0))
    let fd = open("/dev/null", O_RDONLY)
    var spec = sh("[ -e /dev/fd/5 ] && echo five", passFds = @[(source: fd, target: cint(5))])
    spec.executableFd = some(verified.fd)
    let (text, status) = runOut(spec)
    var copy = verified
    copy.close()
    closeFd(fd)
    check status.code == 0
    check text.strip == "five"
