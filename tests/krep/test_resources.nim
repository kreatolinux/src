import std/[os, tempfiles, unittest]
import ../../krep/modules/resources

suite "image resource resolution":
  setup:
    let work = createTempDir("krep-resources-", "")
    let appDir = work / "prefix/bin"
    let sourceDir = work / "source"
    let installed = work / "prefix/share/krep"
    let explicitDir = work / "explicit"
    let envDir = work / "environment"
    let hadEnv = existsEnv("KREP_DATA_DIR")
    let oldEnv = getEnv("KREP_DATA_DIR")
    delEnv("KREP_DATA_DIR")
    createDir(appDir)
    createDir(sourceDir / "rootfs")
    createDir(sourceDir / "iso")
  teardown:
    if hadEnv: putEnv("KREP_DATA_DIR", oldEnv)
    else: delEnv("KREP_DATA_DIR")
    removeDir(work)

  test "source assets are separate and independent of cwd":
    check resolveResourceDir("rootfs", appDir = appDir,
        sourceDir = sourceDir) == sourceDir / "rootfs"
    check resolveResourceDir("iso", appDir = appDir,
        sourceDir = sourceDir) == sourceDir / "iso"

  test "installed assets take priority over the source tree":
    createDir(installed / "rootfs")
    createDir(installed / "iso")
    check resolveResourceDir("rootfs", appDir = appDir,
        sourceDir = sourceDir) == installed / "rootfs"
    check resolveResourceDir("iso", appDir = appDir,
        sourceDir = sourceDir) == installed / "iso"

  test "build-tree assets work without source fallback":
    createDir(appDir / "share/krep/rootfs")
    createDir(appDir / "share/krep/iso")
    check resolveResourceDir("rootfs", appDir = appDir,
        sourceDir = "") == appDir / "share/krep/rootfs"
    check resolveResourceDir("iso", appDir = appDir,
        sourceDir = "") == appDir / "share/krep/iso"

  test "removed project directories are not mistaken for assets":
    createDir(appDir / "kreastrap")
    createDir(appDir / "kreaiso")
    check resolveResourceDir("rootfs", appDir = appDir,
        sourceDir = sourceDir) == sourceDir / "rootfs"
    check resolveResourceDir("iso", appDir = appDir,
        sourceDir = sourceDir) == sourceDir / "iso"

  test "explicit directory overrides environment and installation":
    createDir(explicitDir / "rootfs")
    createDir(envDir / "rootfs")
    createDir(installed / "rootfs")
    putEnv("KREP_DATA_DIR", envDir)
    check resolveResourceDir("rootfs", explicitDir, appDir,
        sourceDir) == explicitDir / "rootfs"

  test "environment directory overrides installation":
    createDir(envDir / "iso")
    createDir(installed / "iso")
    putEnv("KREP_DATA_DIR", envDir)
    check resolveResourceDir("iso", appDir = appDir,
        sourceDir = sourceDir) == envDir / "iso"

  test "removed project names are not resource layouts":
    createDir(explicitDir / "kreastrap/arch")
    createDir(explicitDir / "kreaiso")
    writeFile(explicitDir / "kreaiso/grub.cfg", "template")
    for kind in ["rootfs", "iso"]:
      expect ValueError: discard resolveResourceDir(kind, explicitDir)

  test "command-specific asset directories work":
    createDir(explicitDir / "arch")
    writeFile(explicitDir / "grub.cfg", "template")
    check resolveResourceDir("rootfs", explicitDir) == explicitDir
    check resolveResourceDir("iso", explicitDir) == explicitDir
    check resolveResourceDir("rootfs", appDir = explicitDir,
        sourceDir = "") == explicitDir
    check resolveResourceDir("iso", appDir = explicitDir,
        sourceDir = "") == explicitDir

  test "relative overrides are returned as absolute paths":
    createDir(explicitDir / "rootfs")
    check resolveResourceDir("rootfs", relativePath(explicitDir,
        getCurrentDir())) == explicitDir / "rootfs"

  test "missing explicit assets never fall back to environment or source":
    createDir(envDir / "rootfs")
    putEnv("KREP_DATA_DIR", envDir)
    expect ValueError:
      discard resolveResourceDir("rootfs", explicitDir, appDir, sourceDir)

  test "missing environment assets never fall back to source":
    putEnv("KREP_DATA_DIR", envDir)
    expect ValueError:
      discard resolveResourceDir("iso", appDir = appDir, sourceDir = sourceDir)

  test "rootfs resources cannot silently supply ISO resources":
    createDir(explicitDir / "rootfs")
    expect ValueError:
      discard resolveResourceDir("iso", explicitDir)

  test "missing resources fail clearly":
    expect ValueError:
      discard resolveResourceDir("rootfs", appDir = appDir, sourceDir = "")

  test "unknown kinds and traversal are rejected":
    for kind in ["", "other", "../iso", "/rootfs"]:
      expect ValueError: discard resolveResourceDir(kind, explicitDir)
