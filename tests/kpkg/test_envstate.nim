import std/[os, unittest]
import ../../kpkg/modules/envstate

suite "sandbox postinstall completion":
  let root = getTempDir() / ("kpkg-envstate-" & $getCurrentProcessId())
  var actions: seq[string]

  setup:
    removeDir(root)
    createDir(root / "etc")
    writeFile(root / "etc/kreato-release", "[Core]\nlibc=glibc\n")
    actions = @[]

  teardown:
    removeDir(root)

  test "release file and legacy early date do not prove completion":
    check not canReuseEnv(root)
    writeFile(root / "envDateBuilt", "2026-09-15")
    check not canReuseEnv(root)
    check not canReuseEnv(root, deferPostInstall = true)

  test "normal setup runs trust then postinstall before publishing completion":
    proc trust() =
      actions.add("trust")
      check not canReuseEnv(root)
      check not fileExists(root / "envDateBuilt")
    proc postinstall() =
      actions.add("postinstall")
      check not canReuseEnv(root)
      check not fileExists(root / "envDateBuilt")
    finishEnvSetup(root, trust, postinstall)
    check actions == @["trust", "postinstall"]
    check canReuseEnv(root)
    check canReuseEnv(root, deferPostInstall = true)

  test "deferred repair executes neither callback and has no completion date":
    finishEnvSetup(root,
      proc() = actions.add("trust"),
      proc() = actions.add("postinstall"),
      deferPostInstall = true)
    check actions.len == 0
    check not fileExists(root / "envDateBuilt")
    check not canReuseEnv(root)
    check not canReuseEnv(root, ignorePostInstall = true)
    check canReuseEnv(root, deferPostInstall = true)

  test "normal setup after deferral runs all callbacks":
    markEnvDeferred(root)
    finishEnvSetup(root,
      proc() = actions.add("trust"),
      proc() = actions.add("postinstall"))
    check actions == @["trust", "postinstall"]
    check canReuseEnv(root)

  test "trust failure cannot leave a reusable env or stale completion":
    writeFile(root / envSetupStateFile, "ready-v1")
    writeFile(root / "envDateBuilt", "2026-09-15")
    expect IOError:
      finishEnvSetup(root,
        proc() = raise newException(IOError, "trust failed"),
        proc() = actions.add("postinstall"))
    check actions.len == 0
    check not canReuseEnv(root)
    check not canReuseEnv(root, deferPostInstall = true)
    check not fileExists(root / "envDateBuilt")

  test "postinstall failure cannot leave a reusable env":
    expect IOError:
      finishEnvSetup(root,
        proc() = actions.add("trust"),
        proc() = raise newException(IOError, "postinstall failed"))
    check actions == @["trust"]
    check not canReuseEnv(root)
    check not canReuseEnv(root, deferPostInstall = true)
    check not fileExists(root / "envDateBuilt")

  test "legacy isolation ignore still runs trust but not postinstall":
    finishEnvSetup(root,
      proc() = actions.add("trust"),
      proc() = actions.add("postinstall"),
      ignorePostInstall = true)
    check actions == @["trust"]
    check canReuseEnv(root, ignorePostInstall = true)
    check not canReuseEnv(root)

  test "explicit defer wins over legacy ignore":
    finishEnvSetup(root,
      proc() = actions.add("trust"),
      proc() = actions.add("postinstall"),
      deferPostInstall = true, ignorePostInstall = true)
    check actions.len == 0
    check not canReuseEnv(root, ignorePostInstall = true)
    check canReuseEnv(root, deferPostInstall = true)

  test "repair invalidates a previously complete env":
    finishEnvSetup(root, proc() = discard, proc() = discard)
    check canReuseEnv(root)
    markEnvDeferred(root)
    check not canReuseEnv(root)
    check canReuseEnv(root, deferPostInstall = true)
    check not fileExists(root / "envDateBuilt")

  test "unknown and truncated state are never reusable":
    for state in ["", "ready", "ready-v1\n", "unknown"]:
      writeFile(root / envSetupStateFile, state)
      check not canReuseEnv(root)
      check not canReuseEnv(root, deferPostInstall = true)

  test "ready state needs date and release file":
    writeFile(root / envSetupStateFile, "ready-v1")
    check not canReuseEnv(root)
    writeFile(root / "envDateBuilt", "2026-09-15")
    check canReuseEnv(root)
    removeFile(root / "etc/kreato-release")
    check not canReuseEnv(root)

  test "deferred state needs release file too":
    markEnvDeferred(root)
    removeFile(root / "etc/kreato-release")
    check not canReuseEnv(root, deferPostInstall = true)
