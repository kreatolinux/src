import std/[os, tempfiles, unittest]
import ../../kpkg/modules/[isolation, sqlite]

proc addPackage(root, name, version: string, release = "1", epoch = "",
                deps = "", replaces = "", basePackage = false) =
  discard newPackage(name = name, version = version, release = release,
      epoch = epoch, deps = deps, bdeps = "", backup = "", replaces = replaces,
      license = "", desc = "", manualInstall = false, isGroup = false,
      basePackage = basePackage, root = root)

suite "sandbox root copying":
  let fixture = createTempDir("kpkg-isolation-copy-", "")
  let sourceRoot = fixture / "source"
  let envRoot = fixture / "env"

  teardown:
    closeDb()
    removeDir(fixture)

  test "resolver order remains dependency-first and unique":
    check dependencyFirstPackages(@["shared", "b", "a", "shared", ""]) ==
        @["shared", "b", "a"]

  test "repeated package registration is idempotent and preserves identity":
    addPackage(sourceRoot, "base", "2.0-7", release = "7", epoch = "1",
        deps = "shared", basePackage = true)
    newPackageFromRoot(sourceRoot, "base", envRoot)
    newPackageFromRoot(sourceRoot, "base", envRoot)

    check getListPackages(envRoot) == @["base"]
    let copied = getPackage("base", envRoot)
    check copied.version == "2.0-7"
    check copied.release == "7"
    check copied.epoch == "1"
    check copied.basePackage


  test "replacement provider does not hide a missing exact destination row":
    addPackage(sourceRoot, "virtual", "1-1")
    addPackage(envRoot, "provider", "1-1", replaces = "virtual")
    check packageExists("virtual", envRoot)
    check not packageExistsExact("virtual", envRoot)
    newPackageFromRoot(sourceRoot, "virtual", envRoot)
    check packageExistsExact("virtual", envRoot)
    check getListPackages(envRoot).len == 2

  test "environment comparison uses installed split-package identity":
    addPackage(sourceRoot, "ca-certificates-mozilla", "3.129-4",
        release = "4")
    newPackageFromRoot(sourceRoot, "ca-certificates-mozilla", envRoot)
    check not checkEnvPackageUpdates("ca-certificates-mozilla", sourceRoot,
        envRoot)

    rmPackage("ca-certificates-mozilla", sourceRoot)
    addPackage(sourceRoot, "ca-certificates-mozilla", "3.130-1",
        release = "1")
    check checkEnvPackageUpdates("ca-certificates-mozilla", sourceRoot,
        envRoot)

    rmPackage("ca-certificates-mozilla", sourceRoot)
    check checkEnvPackageUpdates("ca-certificates-mozilla", sourceRoot,
        envRoot)
