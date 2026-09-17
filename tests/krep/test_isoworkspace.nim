import std/[os, tempfiles, unittest]
import posix
import ../../krep/modules/isoworkspace

suite "ISO workspace and publication":
  setup:
    let work = createTempDir("krep-workspace-test-", "")
  teardown:
    removeDir(work)

  test "workspaces are unique, private, and independently cleaned":
    let first = createWorkspace(work)
    let second = createWorkspace(work)
    check first.path != second.path
    check first.path.parentDir == work
    check getFilePermissions(first.path) == {fpUserRead, fpUserWrite, fpUserExec}
    writeFile(second.path / "keep", "other build")
    createDir(first.path / "nested/child")
    writeFile(first.path / "nested/child/data", "build")
    cleanupWorkspace(first)
    cleanupWorkspace(first)
    check not dirExists(first.path)
    check readFile(second.path / "keep") == "other build"
    cleanupWorkspace(second)

  test "cleanup unlinks directory, file, and dangling symlinks":
    let outside = work / "outside"
    createDir(outside)
    writeFile(outside / "keep", "untouched")
    let workspace = createWorkspace(work)
    createDir(workspace.path / "nested")
    createSymlink(outside, workspace.path / "directory-link")
    createSymlink(outside / "keep", workspace.path / "nested/file-link")
    createSymlink(outside / "missing", workspace.path / "dangling-link")
    cleanupWorkspace(workspace)
    check readFile(outside / "keep") == "untouched"
    check not dirExists(workspace.path)

  test "callback workspace cleanup covers success and exceptions":
    var successPath, failurePath: string
    withWorkspace(proc(workspace: IsoWorkspace) =
      successPath = workspace.path
      writeFile(workspace.path / "done", "done"), work)
    check not dirExists(successPath)
    expect ValueError:
      withWorkspace(proc(workspace: IsoWorkspace) =
        failurePath = workspace.path
        createDir(workspace.path / "partial")
        writeFile(workspace.path / "partial/data", "partial")
        raise newException(ValueError, "injected build failure"), work)
    check not dirExists(failurePath)

  test "workspace replacement is not deleted":
    let workspace = createWorkspace(work)
    let original = workspace.path & "-original"
    moveDir(workspace.path, original)
    createDir(workspace.path)
    writeFile(workspace.path / "keep", "replacement")
    expect IOError: cleanupWorkspace(workspace)
    check readFile(workspace.path / "keep") == "replacement"

  test "lock acquisition is exclusive and release is idempotent":
    let output = work / "image.iso"
    let first = acquireOutputLock(output)
    check getFilePermissions(first.lockPath) == {fpUserRead, fpUserWrite, fpUserExec}
    expect OSError: discard acquireOutputLock(output)
    check dirExists(first.lockPath)
    releaseOutputLock(first)
    releaseOutputLock(first)
    let second = acquireOutputLock(output)
    releaseOutputLock(first)
    check dirExists(second.lockPath)
    releaseOutputLock(second)
    check not dirExists(output & ".lock")

  test "another process cannot acquire a held output lock":
    let output = work / "image.iso"
    let lock = acquireOutputLock(output)
    try:
      let child = fork()
      check child >= 0
      if child == 0:
        try:
          let unexpected = acquireOutputLock(output)
          releaseOutputLock(unexpected)
          exitnow(1)
        except OSError:
          exitnow(0)
        except:
          exitnow(2)
      if child > 0:
        var status: cint
        check waitpid(child, status, 0) == child
        check WIFEXITED(status)
        check WEXITSTATUS(status) == 0
      check dirExists(lock.lockPath)
    finally: releaseOutputLock(lock)

  test "preexisting lock is never removed":
    let output = work / "image.iso"
    createDir(output & ".lock")
    writeFile(output & ".lock/owner", "other process")
    expect OSError: discard acquireOutputLock(output)
    check readFile(output & ".lock/owner") == "other process"

  test "replaced lock is never removed":
    let lock = acquireOutputLock(work / "image.iso")
    moveDir(lock.lockPath, work / "old-lock")
    createDir(lock.lockPath)
    expect IOError: releaseOutputLock(lock)
    check dirExists(lock.lockPath)

  test "publish copies full data and preserves staged file":
    let staged = work / "staged.iso"
    let output = work / "image.iso"
    var contents = newString(200_000)
    for i in 0 ..< contents.len: contents[i] = char(i mod 256)
    writeFile(staged, contents)
    let lock = acquireOutputLock(output)
    try:
      publishIso(staged, lock)
      check readFile(output) == contents
      check readFile(staged) == contents
    finally: releaseOutputLock(lock)
    var entries: seq[string]
    for kind, path in walkDir(work): entries.add(path.extractFilename)
    check entries.len == 2

  test "existing output is preserved unless overwrite is explicit":
    let staged = work / "staged.iso"
    let output = work / "image.iso"
    writeFile(staged, "new")
    writeFile(output, "original")
    let lock = acquireOutputLock(output)
    try:
      expect OSError: publishIso(staged, lock)
      check readFile(output) == "original"
      var count = 0
      for kind, path in walkDir(work): inc count
      check count == 3
      publishIso(staged, lock, overwrite = true)
      check readFile(output) == "new"
    finally: releaseOutputLock(lock)

  test "dangling destination symlink counts as existing output":
    let staged = work / "staged.iso"
    let output = work / "image.iso"
    let target = work / "missing"
    writeFile(staged, "new")
    createSymlink(target, output)
    let lock = acquireOutputLock(output)
    try:
      expect OSError: publishIso(staged, lock)
      check symlinkExists(output)
      check not fileExists(target)
      publishIso(staged, lock, overwrite = true)
      check not symlinkExists(output)
      check readFile(output) == "new"
      check not fileExists(target)
    finally: releaseOutputLock(lock)

  test "failed input leaves no output or partial copy":
    let output = work / "image.iso"
    let lock = acquireOutputLock(output)
    try:
      expect IOError: publishIso(work / "missing.iso", lock)
      check not fileExists(output)
      var count = 0
      for kind, path in walkDir(work): inc count
      check count == 1
    finally: releaseOutputLock(lock)

  test "cancellation during copy removes partial and preserves existing output":
    let staged = work / "staged.iso"
    let output = work / "image.iso"
    writeFile(staged, newString(200_000))
    writeFile(output, "original")
    let lock = acquireOutputLock(output)
    var checks = 0
    try:
      expect ValueError:
        publishIso(staged, lock, overwrite = true, checkCancelled = proc() =
          inc checks
          if checks == 2:
            raise newException(ValueError, "injected cancellation"))
      check checks == 2
      check readFile(output) == "original"
      var count = 0
      for kind, path in walkDir(work): inc count
      check count == 3
    finally: releaseOutputLock(lock)

  test "cancellation immediately before publication preserves existing output":
    let staged = work / "staged.iso"
    let output = work / "image.iso"
    writeFile(staged, "new")
    writeFile(output, "original")
    let lock = acquireOutputLock(output)
    var checks = 0
    try:
      expect ValueError:
        publishIso(staged, lock, overwrite = true, checkCancelled = proc() =
          inc checks
          # One data read, one EOF read, then the pre-publication check.
          if checks == 3:
            raise newException(ValueError, "injected cancellation"))
      check checks == 3
      check readFile(output) == "original"
      var count = 0
      for kind, path in walkDir(work): inc count
      check count == 3
    finally: releaseOutputLock(lock)

  test "publish rejects released, replaced, or absent lock":
    let staged = work / "staged.iso"
    writeFile(staged, "new")
    expect IOError: publishIso(staged, nil)
    let lock = acquireOutputLock(work / "image.iso")
    releaseOutputLock(lock)
    expect IOError: publishIso(staged, lock)
    let replacement = acquireOutputLock(work / "image.iso")
    moveDir(replacement.lockPath, work / "old-lock")
    createDir(replacement.lockPath)
    expect IOError: publishIso(staged, replacement)
    expect IOError: releaseOutputLock(replacement)
    check not fileExists(work / "image.iso")
