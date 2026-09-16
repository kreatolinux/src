## Integration fixture: run only in a disposable container. kpkg's repository
## configuration has a fixed /etc path, so normal test runs skip this suite.
## No package records are written outside fresh temporary roots.
## KPKG_DISPOSABLE_TEST_ROOT=1 /tmp/test_getdependents
import std/[unittest, os, tempfiles]
import ../../kpkg/modules/[commonTasks, sqlite]

proc addPackage(root, name, version: string, deps = "", bdeps = "") =
  discard newPackage(name = name, version = version, release = "1", epoch = "",
      deps = deps, bdeps = bdeps, backup = "", replaces = "", license = "",
      desc = "", manualInstall = false, isGroup = false, basePackage = false,
      root = root)

if getEnv("KPKG_DISPOSABLE_TEST_ROOT") != "1":
  suite "getDependents (requires disposable container)":
    test "set KPKG_DISPOSABLE_TEST_ROOT=1 in an isolated container to run":
      skip()
else:
  suite "getDependents provider versions and root isolation":
    var fixture, root, otherRoot, repo, savedConfig: string
    var savedPermissions: set[FilePermission]
    const configPath = "/etc/kpkg/kpkg.conf"

    setup:
      savedConfig = readFile(configPath)
      savedPermissions = getFilePermissions(configPath)
      fixture = createTempDir("kpkg-dependents-", "")
      root = fixture / "target"
      otherRoot = fixture / "other"
      repo = fixture / "repo"
      createDir(repo / "gmp")
      writeFile(repo / "gmp" / "run3",
          "name: \"gmp\"\nversion: \"6.3.0\"\nrelease: \"1\"\n")
      writeFile(configPath, "[Repositories]\nrepoDirs=" & repo & "\n")
      addPackage(root, "gcc", "15.2.0-1", "gmp")

    teardown:
      closeDb()
      writeFile(configPath, savedConfig)
      setFilePermissions(configPath, savedPermissions)
      removeDir(fixture)

    test "current provider does not invalidate a differently versioned consumer":
      addPackage(root, "gmp", "6.3.0-1")
      check getDependents(@["gmp"], root = root).len == 0

    test "older provider invalidates even when consumer equals upstream provider":
      rmPackage("gcc", root)
      addPackage(root, "gcc", "6.3.0-1", "gmp")
      addPackage(root, "gmp", "6.2.0-1")
      check getDependents(@["gmp"], root = root) == @["gcc"]

    test "missing provider conservatively invalidates without loading it":
      check getDependents(@["gmp"], root = root) == @["gcc"]

    test "missing provider does not require repository metadata":
      removeDir(repo / "gmp")
      check getDependents(@["gmp"], root = root) == @["gcc"]

    test "addIfOutdated false returns consumers of a current provider":
      addPackage(root, "gmp", "6.3.0-1")
      check getDependents(@["gmp"], root = root,
          addIfOutdated = false) == @["gcc"]

    test "addIfOutdated false does not require a provider or runfile":
      removeDir(repo / "gmp")
      check getDependents(@["gmp"], root = root,
          addIfOutdated = false) == @["gcc"]

    test "enumeration and provider lookup stay within the requested root":
      addPackage(root, "gmp", "6.3.0-1")
      addPackage(otherRoot, "target-only", "9-1", "gmp")
      addPackage(otherRoot, "gmp", "6.2.0-1")
      check getDependents(@["gmp"], root = root).len == 0
      check getDependents(@["gmp"], root = otherRoot) == @["target-only"]
      check getDependents(@["gmp"], root = root,
          addIfOutdated = false) == @["gcc"]

    test "unrelated packages and build-only dependencies are not returned":
      addPackage(root, "gmp", "6.2.0-1")
      addPackage(root, "unrelated", "3-1")
      addPackage(root, "build-only", "4-1", bdeps = "gmp")
      check getDependents(@["gmp"], root = root) == @["gcc"]
      check getDependents(@["unrelated"], root = root).len == 0
      check getDependents(@[], root = root).len == 0
