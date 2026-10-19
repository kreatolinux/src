import std/[os, posix, unittest]
import jumpstartcore/peercred

suite "peercred":
  test "parses /proc stat fields after a comm containing parentheses":
    let stat = "42 (a b) c) S 1 42 42 0 -1 4194560 100 0 0 0 1 2 0 0 20 0 1 0 987654 1000 10 18446744073709551615"
    check parseStatStartTime(stat) == 987654
    check parseStatState(stat) == 'S'
    check parseStatFlags(stat) == 4194560'u64

  test "malformed stat text is rejected":
    expect ValueError: discard parseStatStartTime("no parentheses here")
    expect ValueError: discard parseStatState("1 (x)")

  test "parses the real uid from /proc status":
    check parseStatusRealUid("Name:\tx\nUid:\t1000\t1000\t1000\t1000\n") == 1000
    expect ValueError: discard parseStatusRealUid("Name:\tx\n")

  test "process identity readers accept an injected proc root":
    let root = getTempDir() / ("jumpstartcore-proc-" & $getCurrentProcessId())
    createDir(root / "7")
    defer: removeDir(root)
    writeFile(root / "7" / "stat", "7 (x) S 1 7 7 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 555 1 1 1")
    writeFile(root / "7" / "status", "Name:\tx\nUid:\t33\t33\t33\t33\n")
    check processStartTicks(7, root) == 555
    check processRealUid(7, root) == 33

  test "peerCredentials of a socketpair is this process":
    var fds: array[2, cint]
    check socketpair(AF_UNIX, SOCK_STREAM, 0, fds) == 0
    let info = peerCredentials(fds[0])
    check info.uid == int64(geteuid())
    check info.gid == int64(getegid())
    discard close(fds[0]); discard close(fds[1])
