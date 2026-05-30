import unittest
import std/[os, sequtils]
import ../../kpkg/modules/builder/soname

suite "SONAME change detection":

  test "getBuildSonames finds versioned .so files":
    let testDir = getTempDir() / "kpkg_soname_test"
    createDir(testDir / "usr" / "lib")

    writeFile(testDir / "usr" / "lib" / "libssl.so.4", "")
    writeFile(testDir / "usr" / "lib" / "libcrypto.so.81", "")
    writeFile(testDir / "usr" / "lib" / "libfoo.a", "")
    writeFile(testDir / "usr" / "lib" / "libbar.so", "")

    let sonames = getBuildSonames(testDir)

    check sonames.len == 2
    check "libssl.so.4" in sonames
    check "libcrypto.so.81" in sonames

    removeDir(testDir)

  test "getBuildSonames returns empty for non-library builds":
    let testDir = getTempDir() / "kpkg_soname_test2"
    createDir(testDir / "usr" / "bin")
    writeFile(testDir / "usr" / "bin" / "git", "")

    let sonames = getBuildSonames(testDir)
    check sonames.len == 0

    removeDir(testDir)
