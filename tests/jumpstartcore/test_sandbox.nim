import std/[os, unittest]
import jumpstartcore/sandbox

proc fsSystem(): SandboxSystem =
  result.exists = proc(path: string): bool = fileExists(path) or dirExists(path)
  result.isDir = proc(path: string): bool = dirExists(path)

suite "sandbox policy and fail-closed setup":
  test "writable paths and working directory validate under a temp root":
    let temp = getTempDir() / "jumpstart-sandbox-test"
    if dirExists(temp): removeDir(temp)
    let state = temp / "state"
    let run = temp / "run"
    createDir(state / "work")
    createDir(run)
    let config = SandboxConfig(stateDir: state, runtimeDir: run,
      writablePaths: @[state], workingDirectory: state / "work")
    let paths = validateSandbox(config, fsSystem())
    check state in paths
    check run in paths
    removeDir(temp)

  test "missing paths are skipped and unsafe paths are rejected":
    let temp = getTempDir() / "jumpstart-sandbox-invalid"
    if dirExists(temp): removeDir(temp)
    createDir(temp)
    check writableSandboxPaths(SandboxConfig(writablePaths: @[temp / "missing"]),
      fsSystem()).len == 0
    expect SandboxError:
      discard validateSandbox(SandboxConfig(writablePaths: @["relative"],
        workingDirectory: "/"), fsSystem())
    expect SandboxError:
      discard validateSandbox(SandboxConfig(writablePaths: @[temp],
        workingDirectory: "/"), fsSystem())
    removeDir(temp)

  test "the private /tmp is a valid working directory, its contents are not":
    # §13.8: /tmp is a fresh private tmpfs, so only /tmp itself exists there.
    check validateSandbox(SandboxConfig(workingDirectory: "/tmp"), fsSystem()).len == 0
    expect SandboxError:
      discard validateSandbox(SandboxConfig(workingDirectory: "/tmp/other"), fsSystem())
    expect SandboxError:
      discard validateSandbox(SandboxConfig(workingDirectory: "/"), fsSystem())

  test "portable default never runs unsandboxed":
    let temp = getTempDir() / "jumpstart-sandbox-closed"
    if dirExists(temp): removeDir(temp)
    createDir(temp)
    expect SandboxError:
      enterSandbox(SandboxConfig(stateDir: temp, workingDirectory: temp),
        defaultSandboxSystem())
    removeDir(temp)

  test "injected setup applies every required restriction in order":
    let temp = getTempDir() / "jumpstart-sandbox-injected"
    if dirExists(temp): removeDir(temp)
    createDir(temp)
    var calls: seq[string]
    var denied: seq[string]
    var sys = fsSystem()
    sys.available = proc(): bool = true
    sys.unshareMountPidIpcUts = proc() = calls.add("namespaces")
    sys.unshareNetwork = proc() = calls.add("network")
    sys.makeMountsPrivate = proc() = calls.add("private")
    sys.remountRootReadOnly = proc() = calls.add("readonly")
    sys.mountPrivateTmp = proc() = calls.add("tmp")
    sys.exposeWritable = proc(path: string) = calls.add("writable:" & path)
    sys.bringLoopbackUp = proc() = calls.add("loopback")
    sys.dropAllCapabilities = proc() = calls.add("caps")
    sys.setNoNewPrivileges = proc() = calls.add("nnp")
    sys.installDenySeccomp = proc(names: openArray[string]) = denied = @names
    sys.changeDirectory = proc(path: string) = calls.add("chdir:" & path)
    enterSandbox(SandboxConfig(stateDir: temp, workingDirectory: temp), sys)
    check calls == @["namespaces", "network", "private", "readonly", "tmp",
      "writable:" & temp, "loopback", "caps", "nnp", "chdir:" & temp]
    for name in DeniedSandboxSyscalls: check name in denied
    removeDir(temp)

suite "sandbox preparation":
  test "writable paths under forbidden roots are rejected (§13.1)":
    let temp = getTempDir() / "jumpstart-sandbox-forbidden"
    if dirExists(temp): removeDir(temp)
    createDir(temp / "home" / "alice")
    defer: removeDir(temp)
    expect SandboxError:
      discard writableSandboxPaths(SandboxConfig(writablePaths: @[temp / "home" / "alice"],
        forbiddenRoots: @[temp / "home"]), fsSystem())
    check writableSandboxPaths(SandboxConfig(writablePaths: @[temp / "home" / "alice"],
      forbiddenRoots: @[temp / "other"]), fsSystem()).len == 1

  test "a symlink into a forbidden root is refused by where it leads (§13.1, §13.8)":
    let temp = getTempDir() / "jumpstart-sandbox-symlink"
    if dirExists(temp): removeDir(temp)
    createDir(temp / "home" / "alice")
    createDir(temp / "state" / "work")
    defer: removeDir(temp)
    createSymlink(temp / "home" / "alice", temp / "state" / "link")
    createSymlink(temp / "home", temp / "state" / "homelink")
    createSymlink(temp / "nowhere", temp / "state" / "dangling")
    let forbidden = @[temp / "home"]
    # Through a link to a directory under the root, and to the root itself.
    for path in [temp / "state" / "link", temp / "state" / "homelink"]:
      expect SandboxError:
        discard writableSandboxPaths(SandboxConfig(writablePaths: @[path],
          forbiddenRoots: forbidden), fsSystem())
    # A not-yet-existing path below a link is resolved through the link too.
    expect SandboxError:
      discard writableSandboxPaths(SandboxConfig(
        writablePaths: @[temp / "state" / "link" / "new" / "deeper"],
        forbiddenRoots: forbidden), fsSystem())
    # A dangling link could point anywhere later: fail closed.
    expect SandboxError:
      discard writableSandboxPaths(SandboxConfig(writablePaths: @[temp / "state" / "dangling"],
        forbiddenRoots: forbidden), fsSystem())
    # A forbidden root reached through a link is resolved as well.
    createSymlink(temp / "home", temp / "rootlink")
    expect SandboxError:
      discard writableSandboxPaths(SandboxConfig(writablePaths: @[temp / "home" / "alice"],
        forbiddenRoots: @[temp / "rootlink"]), fsSystem())
    # Ordinary paths outside the roots and links to them stay allowed.
    createSymlink(temp / "state" / "work", temp / "state" / "worklink")
    check writableSandboxPaths(SandboxConfig(writablePaths: @[temp / "state" / "worklink"],
      forbiddenRoots: forbidden), fsSystem()).len == 1

  test "preparation fails closed where the platform cannot sandbox":
    let temp = getTempDir() / "jumpstart-sandbox-prepare"
    if dirExists(temp): removeDir(temp)
    createDir(temp)
    defer: removeDir(temp)
    when defined(linux):
      if sandboxSupported():
        let prepared = prepareSandbox(SandboxConfig(stateDir: temp, workingDirectory: temp))
        check prepared.writable == @[temp]
      else:
        expect SandboxError:
          discard prepareSandbox(SandboxConfig(stateDir: temp, workingDirectory: temp))
    else:
      check not sandboxSupported()
      expect SandboxError:
        discard prepareSandbox(SandboxConfig(stateDir: temp, workingDirectory: temp))
    # Working directory outside writable paths is refused before anything else.
    expect SandboxError:
      discard prepareSandbox(SandboxConfig(stateDir: temp, workingDirectory: "/"))
