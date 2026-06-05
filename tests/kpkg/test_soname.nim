import unittest
import std/os
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

  test "parseNeededSonames finds ELF NEEDED libraries":
    let readelfOutput = """
Dynamic section at offset 0x2dd8 contains 29 entries:
  Tag        Type                         Name/Value
 0x0000000000000001 (NEEDED)             Shared library: [libssl.so.3]
 0x0000000000000001 (NEEDED)             Shared library: [libcrypto.so.3]
 0x000000000000001d (RUNPATH)            Library runpath: [/usr/lib]
"""

    let needed = parseNeededSonames(readelfOutput)

    check needed == @["libssl.so.3", "libcrypto.so.3"]

  test "orderSonameConsumers places rebuilt runtime deps first":
    let ordered = orderSonameConsumers(@["git", "curl", "libarchive"],
        proc(pkg: string): seq[string] =
      if pkg == "git":
        return @["curl", "openssl"]
      return @[])

    check ordered == @["curl", "git", "libarchive"]
