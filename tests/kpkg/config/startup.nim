# Isolated filesystem coverage:
# nim c -r -d:kpkgConfigPath=/tmp/kpkg-config-startup-test/kpkg.conf \
#   tests/kpkg/config/startup.nim
import std/unittest
include ../../../kpkg/modules/config

suite "configuration startup":
  test "import leaves configuration unloaded":
    check config.isNil

when kpkgConfigPath != "/etc/kpkg/kpkg.conf":
  # The compile-time override must point to a disposable test directory.
  suite "lazy configuration access":
    setup:
      config = nil
      createDir(parentDir(configPath))
      writeFile(configPath, "[Options]\ncc=clang\n[Custom]\nanswer=42\n")

    teardown:
      config = nil
      removeFile(configPath)

    test "value getter works as first access":
      check getConfigValue("Options", "cc") == "clang"
      check getConfigValue("Custom", "missing", "fallback") == "fallback"

    test "section enumeration works as first access":
      check configSectionNames() == @["Options", "Custom"]

    test "key enumeration works as first access":
      check configKeyNames("Custom") == @["answer"]
      check configKeyNames("missing").len == 0

    test "section getter works as first access":
      check getConfigSection("Custom") == "answer=42"
      check getConfigSection("missing") == ""

    test "setter works as first access and retains existing values":
      setConfigValue("Custom", "extra", "yes")
      let saved = loadConfig(configPath)
      check saved.getSectionValue("Custom", "answer") == "42"
      check saved.getSectionValue("Custom", "extra") == "yes"
      check saved.getSectionValue("Options", "cc") == "clang"
      check getFilePermissions(configPath) == {fpUserRead, fpUserWrite}

    test "value getters still refresh external changes":
      check getConfigValue("Options", "cc") == "clang"
      writeFile(configPath, "[Options]\ncc=gcc\n")
      check getConfigValue("Options", "cc") == "gcc"

    test "missing file supplies defaults through every accessor":
      removeFile(configPath)
      check "Options" in configSectionNames()
      check "cc" in configKeyNames("Options")
      check getConfigValue("Options", "cc") == "gcc"
      check "cc=gcc" in getConfigSection("Options")
      check fileExists(configPath) == isAdmin()
      if not fileExists(configPath):
        # teardown expects a file, but unprivileged access must not create one.
        writeFile(configPath, "")
