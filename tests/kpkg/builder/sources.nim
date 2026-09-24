import std/[os, posix, tempfiles, unittest]
import ../../../kpkg/modules/builder/sources

suite "builder local source staging":
  let fixture = createTempDir("kpkg-local-source-", "")
  let repository = fixture / "repository"
  let buildRoot = fixture / "build"
  let external = fixture / "external"

  setup:
    createDir(repository / "overlay" / "etc")
    createDir(buildRoot)
    writeFile(repository / "overlay" / "etc" / "unit", "original")
    writeFile(repository / "overlay" / "tool", "#!/bin/sh\n")
    writeFile(external, "outside")
    createSymlink(external, repository / "overlay" / "external-link")
    setFilePermissions(repository / "overlay" / "tool", {fpUserExec,
        fpUserWrite, fpUserRead, fpGroupExec, fpGroupRead, fpOthersExec,
        fpOthersRead})
    setFilePermissions(repository / "overlay", {fpUserExec, fpUserRead,
        fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})

  teardown:
    setFilePermissions(repository / "overlay", {fpUserExec, fpUserWrite,
        fpUserRead, fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})
    removeDir(fixture)

  test "read-only local directory is copied instead of symlinked":
    stageLocalSource(repository / "overlay", buildRoot)
    check dirExists(buildRoot / "overlay")
    check not symlinkExists(buildRoot / "overlay")
    check fpUserExec in getFilePermissions(buildRoot / "overlay" / "tool")
    check symlinkExists(buildRoot / "overlay" / "external-link")
    var beforeStat, afterStat: Stat
    check posix.stat(cstring(external), beforeStat) == 0
    setSourceOwnership(buildRoot / "overlay")
    check posix.stat(cstring(external), afterStat) == 0
    check afterStat.st_uid == beforeStat.st_uid
    check afterStat.st_gid == beforeStat.st_gid
    writeFile(buildRoot / "overlay" / "etc" / "unit", "changed")
    check readFile(repository / "overlay" / "etc" / "unit") == "original"

suite "builder source ownership":
  test "source owner matches execution identity without following links":
    let fixture = createTempDir("kpkg-source-owner-", "")
    defer: removeDir(fixture)
    let source = fixture / "source"
    let external = fixture / "external"
    createDir(source / "nested")
    writeFile(source / "nested" / "unit", "source")
    writeFile(external, "outside")
    createSymlink(external, source / "external-link")
    var beforeStat, afterStat: Stat
    check posix.stat(cstring(external), beforeStat) == 0
    # Root test runs also reproduce the ownership left by older kpkg builds.
    if geteuid() == Uid(0):
      for relative in ["", "nested", "nested/unit", "external-link"]:
        check posix.lchown(cstring(source / relative), Uid(999), Gid(999)) == 0
    setSourceOwnership(source)
    for relative in ["", "nested", "nested/unit", "external-link"]:
      var entryStat: Stat
      check posix.lstat(cstring(source / relative), entryStat) == 0
      check entryStat.st_uid == geteuid()
      check entryStat.st_gid == getegid()
    check posix.stat(cstring(external), afterStat) == 0
    check afterStat.st_uid == beforeStat.st_uid
    check afterStat.st_gid == beforeStat.st_gid
    check fpUserWrite in getFilePermissions(source)
    check fpOthersWrite notin getFilePermissions(source)
    writeFile(source / "config.log", "configure can write")
