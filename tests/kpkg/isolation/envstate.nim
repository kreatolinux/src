import std/[os, unittest]
import ../../../kpkg/modules/envstate
import ../../../kpkg/modules/rootfs/[profile, state, types]

proc profile(): RootfsProfile =
  result = RootfsProfile(schemaVersion: 1, arch: "x86_64", os: "linux",
    libc: "glibc", compiler: "gcc", coreutils: "gnu", init: "systemd",
    tlsLibrary: "openssl", packageRoots: @["gnu-core", "dbus", "systemd"])
  finalizeProfile(result)

suite "sandbox Kongue completion state":
  let root = getTempDir() / ("kpkg-envstate-" & $getCurrentProcessId())
  var actions: seq[string]
  setup:
    removeDir(root)
    createDir(root / "etc")
    writeFile(root / "etc/kreato-release", "[Core]\nlibc=glibc\n")
    initializeEnvState(root, profile(), profile().packageRoots)
    actions = @[]
  teardown: removeDir(root)

  test "provisioning state is never reusable":
    check not canReuseEnv(root)
    check loadRootfsState(root / rootfsStateFile).status == rsProvisioning

  test "normal setup publishes ready only after finalizers":
    finishEnvSetup(root,
      proc() = (actions.add("trust"); check not canReuseEnv(root)),
      proc() = (actions.add("postinstall"); check not canReuseEnv(root)))
    check actions == @["trust", "postinstall"]
    check canReuseEnv(root)
    check loadRootfsState(root / rootfsStateFile).phase == rpComplete

  test "deferred roots are explicit and normal builds reject them":
    finishEnvSetup(root, proc() = actions.add("trust"),
      proc() = actions.add("postinstall"), deferPostInstall = true)
    check actions.len == 0
    check not canReuseEnv(root)
    check canReuseEnv(root, deferPostInstall = true)

  test "failure never marks ready":
    expect IOError:
      finishEnvSetup(root,
        proc() = actions.add("trust"),
        proc() = raise newException(IOError, "postinstall failed"))
    check actions == @["trust"]
    check not canReuseEnv(root)
    check loadRootfsState(root / rootfsStateFile).status == rsFailed

  test "pending profile conversion cannot publish ready":
    finishEnvSetup(root, proc() = discard, proc() = discard,
      publishReady = false)
    check not canReuseEnv(root)
    check loadRootfsState(root / rootfsStateFile).phase == rpFinalizing

  test "mismatched or corrupt identity is rejected":
    var current = loadRootfsState(root / rootfsStateFile)
    current.profileFingerprint = "sha256:bad"
    writeRootfsState(root / rootfsStateFile, current)
    check not canReuseEnv(root)
