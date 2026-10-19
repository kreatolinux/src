import std/[os, posix, strutils, unittest]
import jumpstartcore/[errors, verified_file]

proc scratch(name: string): string =
  result = getTempDir() / ("jumpstartcore-verified-" & name & "-" & $getCurrentProcessId())
  removeDir(result)
  createDir(result)

suite "verified_file":
  test "reads a private regular file owned by the trusted uid":
    let dir = scratch("ok")
    defer: removeDir(dir)
    let path = dir / "init.kg"
    writeFile(path, "hello\n")
    setFilePermissions(path, {fpUserRead, fpUserWrite, fpGroupRead, fpOthersRead})
    check readVerifiedFile(path, geteuid()) == "hello\n"

  test "refuses group- and world-writable files":
    let dir = scratch("writable")
    defer: removeDir(dir)
    let path = dir / "init.kg"
    writeFile(path, "x")
    setFilePermissions(path, {fpUserRead, fpUserWrite, fpGroupWrite})
    try:
      discard readVerifiedFile(path, geteuid())
      check false
    except CoreError as e:
      check e.code == ecPermission

  test "refuses symbolic links and relative paths":
    let dir = scratch("link")
    defer: removeDir(dir)
    writeFile(dir / "real", "x")
    createSymlink(dir / "real", dir / "link")
    try:
      discard readVerifiedFile(dir / "link", geteuid())
      check false
    except CoreError as e:
      check e.code == ecPermission
    try:
      discard readVerifiedFile("relative/path", geteuid())
      check false
    except CoreError as e:
      check e.code == ecPermission

  test "refuses a file owned by somebody else":
    let dir = scratch("owner")
    defer: removeDir(dir)
    let path = dir / "init.kg"
    writeFile(path, "x")
    if geteuid() != 0:
      # Neither the trusted uid nor root owns it.
      try:
        discard readVerifiedFile(path, geteuid() + 1)
        check false
      except CoreError as e:
        check e.code == ecPermission
