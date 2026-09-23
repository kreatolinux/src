import std/[tables, unittest]
import ../../../kpkg/modules/builder/types

proc sandboxConfig(deferPostInstall = false): SandboxConfig =
  initSandboxConfig(fullRootPath = "/", target = "default", bootstrap = false,
    forceInstallAll = false, isInstallDir = false, ignoreInit = false,
    dontInstall = false, useCacheIfAvailable = true, tests = true,
    isUpgrade = false, ignorePostInstall = false, manualInstallList = @[],
    ignoreUseCacheIfAvailable = @[], root = "/",
    pkgPaths = initTable[string, string](), deferPostInstall = deferPostInstall)

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
