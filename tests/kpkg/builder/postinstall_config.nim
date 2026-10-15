import std/[os, strutils, tables, unittest]
import ../../../kpkg/modules/builder/types
import ../../../kpkg/modules/commonTasks

proc sandboxConfig(deferPostInstall = false): SandboxConfig =
  initSandboxConfig(fullRootPath = "/", target = "default", bootstrap = false,
    forceInstallAll = false, isInstallDir = false, ignoreInit = false,
    dontInstall = false, useCacheIfAvailable = true, tests = true,
    isUpgrade = false, ignorePostInstall = false, manualInstallList = @[],
    ignoreUseCacheIfAvailable = @[], root = "/",
    pkgPaths = initTable[string, string](), deferPostInstall = deferPostInstall)

suite "sandbox target selection":
  test "normal builds initialize the requested target sandbox":
    let cfg = initSandboxConfig(fullRootPath = "/", target =
      "x86_64-linux-gnu-systemd-openssl", bootstrap = false,
      forceInstallAll = false, isInstallDir = false, ignoreInit = false,
      dontInstall = false, useCacheIfAvailable = true, tests = true,
      isUpgrade = false, ignorePostInstall = false, manualInstallList = @[],
      ignoreUseCacheIfAvailable = @[], root = "/",
      pkgPaths = initTable[string, string]())

    check cfg.target == "x86_64-linux-gnu-systemd-openssl"
    check cfg.sandboxTarget == cfg.target

  test "rootfs bootstrap builds target artifacts in a host sandbox":
    let cfg = initSandboxConfig(fullRootPath = "/", target =
      "x86_64-linux-gnu-systemd-openssl", bootstrap = false,
      forceInstallAll = true, isInstallDir = false, ignoreInit = false,
      dontInstall = true, useCacheIfAvailable = true, tests = true,
      isUpgrade = false, ignorePostInstall = false, manualInstallList = @[],
      ignoreUseCacheIfAvailable = @[], root = "/",
      pkgPaths = initTable[string, string](), sandboxTarget = "default")

    check cfg.target == "x86_64-linux-gnu-systemd-openssl"
    check cfg.sandboxTarget == "default"

suite "explicit postinstall deferral config":
  test "build defaults run hooks with sandbox enabled":
    let cfg = initBuildConfig("test", "/")
    check not cfg.deferPostInstall
    check not cfg.ignorePostInstall
    check not cfg.noSandbox

  test "ignore failure is independent of defer":
    let cfg = initBuildConfig("test", "/", ignorePostInstall = true)
    check cfg.ignorePostInstall
    check not cfg.deferPostInstall

  test "build deferral does not disable the sandbox":
    let cfg = initBuildConfig("test", "/", deferPostInstall = true)
    check cfg.deferPostInstall
    check not cfg.ignorePostInstall
    check not cfg.noSandbox

  test "sandbox defaults run hooks":
    let cfg = sandboxConfig()
    check not cfg.deferPostInstall
    check not cfg.noSandbox

  test "sandbox constructor preserves explicit deferral":
    let cfg = sandboxConfig(deferPostInstall = true)
    check cfg.deferPostInstall
    check not cfg.ignorePostInstall
    check not cfg.noSandbox

  test "install callback defaults run hooks":
    let cfg = InstallConfig()
    check not cfg.deferPostInstall
    check not cfg.ignorePostInstall


suite "native target variants":
  let root = getTempDir() / ("kpkg-target-variants-" & $getCurrentProcessId())

  setup:
    createDir(root / "etc")
    writeFile(root / "etc/kreato-release",
      "[Core]\nlibc=glibc\ncoreutils=busybox\ninit=jumpstart\ntlsLibrary=openssl\n")

  teardown:
    removeDir(root)

  test "init and TLS suffixes do not imply cross-compilation":
    let hostSystem = systemTarget(root)
    check not isCrossTarget(hostSystem & "-systemd-openssl", root)
    check targetInit(hostSystem & "-systemd-openssl", root) == "systemd"

  test "different architecture remains cross-compilation":
    let hostSystem = systemTarget(root)
    let foreignArch = if hostSystem.startsWith("aarch64-"): "x86_64" else: "aarch64"
    check isCrossTarget(foreignArch & "-linux-gnu-systemd-openssl", root)

  test "default target needs no extra variant packages":
    check targetSandboxPackages("default", root).len == 0

  test "systemd native target adds its sandbox base packages":
    let target = systemTarget(root) & "-systemd-openssl"
    check targetCoreutils(target, root) == "gnu"
    check targetSandboxPackages(target, root) ==
      @["gnu-core", "dbus", "systemd"]
    check targetSandboxReplacedPackages(target, root) ==
      @["busybox", "jumpstart"]

  test "cross target does not use host sandbox packages":
    let hostSystem = systemTarget(root)
    let foreignArch = if hostSystem.startsWith("aarch64-"): "x86_64" else: "aarch64"
    check targetSandboxPackages(
      foreignArch & "-linux-gnu-systemd-openssl", root).len == 0

  test "matching system triplet is native":
    check not isCrossTarget(systemTarget(root), root)

  test "different libc and OS remain cross targets":
    let arch = systemTarget(root).split("-")[0]
    check isCrossTarget(arch & "-linux-musl-systemd-openssl", root)
    check isCrossTarget(arch & "-other-gnu-systemd-openssl", root)

  test "TLS variant adds its provider without changing native classification":
    let target = systemTarget(root) & "-jumpstart-libressl"
    check not isCrossTarget(target, root)
    check targetSandboxPackages(target, root) == @["libressl"]

  test "systemd host already supplies systemd and dbus":
    writeFile(root / "etc/kreato-release",
      "[Core]\nlibc=glibc\ncoreutils=gnu\ninit=systemd\ntlsLibrary=openssl\n")
    check targetSandboxPackages(systemTarget(root) & "-systemd-openssl", root).len == 0
