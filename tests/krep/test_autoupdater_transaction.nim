## Transaction and validation tests for the krep run3 autoupdater.
import std/[os, strutils, tempfiles, unittest]
import ../../kpkg/modules/run3/run3
import ../../krep/modules/autoupdater

proc makePackage(root, body: string): string =
  result = root / "package"
  createDir(result)
  writeFile(result / "run3", body)

suite "transactional krep autoupdater":
  setup:
    let work = createTempDir("krep autoupdater test-", "")
  teardown:
    removeDir(work)

  test "local and SKIP sources are retained while metadata changes atomically":
    let packageDir = makePackage(work, """name: sample
version: "1.0"
release: "1"
sources:
        - "local.patch"
        - "https://invalid.example/${version}.tar.gz"
sha256sum:
        - "local-checksum"
        - "SKIP"
""")
    writeFile(packageDir / "local.patch", "patch")
    let recipe = parseRun3(packageDir)

    autoUpdater(recipe, packageDir, "2.0", false, "2")

    let updated = readFile(packageDir / "run3")
    check updated.contains("version: \"2.0\"")
    check updated.contains("release: \"2\"")
    check "local-checksum" in updated
    check "SKIP" in updated

  test "source checksum mismatch fails before changing recipe":
    let packageDir = makePackage(work, """name: mismatch
version: 1.0
release: 1
sources:
        - "one.patch"
        - "two.patch"
sha256sum:
        - "first"
""")
    let original = readFile(packageDir / "run3")
    let recipe = parseRun3(packageDir)

    expect ValueError:
      autoUpdater(recipe, packageDir, "2.0", false)
    check readFile(packageDir / "run3") == original

  test "ambiguous version metadata fails without changing recipe":
    let packageDir = makePackage(work, """name: ambiguous
version: 1.0
version: 1.0
release: 1
sources:
        - "local.patch"
sha256sum:
        - "SKIP"
""")
    let original = readFile(packageDir / "run3")
    let recipe = parseRun3(packageDir)

    expect ValueError:
      autoUpdater(recipe, packageDir, "2.0", false)
    check readFile(packageDir / "run3") == original

  test "download failure rolls back all checksum and metadata changes":
    let packageDir = makePackage(work, """name: rollback
version: 1.0
release: 1
sources:
        - "https://example.invalid/${version}-one.tar.gz"
        - "https://example.invalid/${version}-two.tar.gz"
sha256sum:
        - "old-one"
        - "old-two"
""")
    let original = readFile(packageDir / "run3")
    let recipe = parseRun3(packageDir)
    var calls = 0
    let failingFetcher: SourceFetcher = proc(source, destination: string) =
      inc calls
      if calls == 1:
        writeFile(destination, "first source")
      else:
        raise newException(IOError, "second source failed")

    autoUpdaterWithFetcher(recipe, packageDir, "2.0", true, "",
      failingFetcher)
    check calls == 2
    check readFile(packageDir / "run3") == original
    check getCurrentDir() != packageDir

  test "download failure propagates without changing the recipe":
    let packageDir = makePackage(work, """name: propagate
version: 1.0
release: 1
sources:
        - "https://example.invalid/${version}.tar.gz"
sha256sum:
        - "old-sum"
""")
    let original = readFile(packageDir / "run3")
    let recipe = parseRun3(packageDir)
    let failingFetcher: SourceFetcher = proc(source, destination: string) =
      raise newException(IOError, "fetch failed")

    expect IOError:
      autoUpdaterWithFetcher(recipe, packageDir, "2.0", false, "",
        failingFetcher)
    check readFile(packageDir / "run3") == original

  test "duplicate old checksums are replaced by list position":
    let packageDir = makePackage(work, """name: duplicate-sums
version: 1.0
release: 1
sources:
        - "https://example.invalid/${version}-one.tar.gz"
        - "https://example.invalid/${version}-two.tar.gz"
sha256sum:
        - "same-old-sum"
        - "same-old-sum"
""")
    let recipe = parseRun3(packageDir)
    let fetcher: SourceFetcher = proc(source, destination: string) =
      writeFile(destination, source)
    autoUpdaterWithFetcher(recipe, packageDir, "2.0", false, "", fetcher)
    let updated = parseRun3(packageDir)
    check updated.getVersion() == "2.0"
    check updated.getSha256sum().len == 2
    check updated.getSha256sum()[0] != "same-old-sum"
    check updated.getSha256sum()[1] != "same-old-sum"
    check updated.getSha256sum()[0] != updated.getSha256sum()[1]
    let bytes = readFile(packageDir / "run3")
    check bytes.endsWith("\n")
    check not bytes.endsWith("\n\n")
