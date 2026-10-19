import std/[os, posix, sequtils, strutils, tempfiles, unittest]
import ../../jumpstart/cores/manifest/discovery, ../../jumpstart/cores/lifecycle/state

proc secureTempRoot(): string =
  ## Tests use the system temp dir, never a home directory (§27).
  getTempDir()

proc fixtureOptions(base: string): DiscoveryOptions =
  ## Unprivileged tests stand in for root as the system root's trusted owner.
  ## Proper ancestors of the fixture stand in for a secure installation
  ## prefix, since Linux /tmp is world-writable and §8.3 rejects that.
  let lexical = normalizedPath(base)
  let real = expandFilename(base)
  DiscoveryOptions(systemOwner: getuid(), lstat: proc(path: string; st: var Stat): cint =
    result = posix.lstat(path.cstring, st)
    let p = normalizedPath(path)
    if result == 0 and (p == "/" or lexical.startsWith(p & "/") or real.startsWith(p & "/")):
      st.st_mode = Mode(int(st.st_mode) and not 0o022))

proc privateDir(path: string) =
  createDir(path)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})

proc manifest(path, name: string) =
  writeFile(path / "init.kg", name)
  setFilePermissions(path / "init.kg", {fpUserRead, fpUserWrite})

proc inspector(path: string): ManifestInfo =
  ManifestInfo(name: readFile(path), modes: {cmSystem, cmUser})

suite "core discovery foundation":
  test "names obey the core grammar and reservations":
    check validCoreName("a")
    check validCoreName("SysV-2_core")
    check not validCoreName("2bad")
    check not validCoreName("serviceHandler")
    check validCoreName("serviceHandler", extension = false)
    check not validCoreName("a".repeat(65))

  test "listing is deterministic and invalid entries are isolated":
    let base = createTempDir("jump-discovery-", "", secureTempRoot())
    defer: removeDir(base)
    privateDir(base)
    let root = base / "cores"
    privateDir(root)
    for name in ["zeta", "Alpha"]:
      privateDir(root / name); manifest(root / name, name)
    writeFile(root / "not_a_dir", "")
    let got = discoverCores(cmSystem,
      [CoreRoot(path: root)], inspector, fixtureOptions(base))
    check got.cores.mapIt(it.name) == @["serviceHandler", "Alpha", "zeta"]
    check got.rejected.len == 1
    check got.rejected[0].code == E_LAYOUT

  test "symlinks and escaping references are rejected":
    let base = createTempDir("jump-security-", "", secureTempRoot())
    defer: removeDir(base)
    privateDir(base)
    let root = base / "cores"; privateDir(root)
    privateDir(root / "linked"); manifest(root / "linked", "linked")
    createSymlink(root / "linked" / "init.kg", root / "linked" / "bad")
    privateDir(root / "escape"); manifest(root / "escape", "escape")
    proc inspectEscape(path: string): ManifestInfo =
      result = inspector(path)
      if result.name == "escape": result.referencedPaths = @["../outside"]
    let got = discoverCores(cmSystem,
      [CoreRoot(path: root)], inspectEscape, fixtureOptions(base))
    check got.cores.len == 1
    check got.rejected.mapIt(it.code) == @[E_LAYOUT, E_LAYOUT]

suite "enabled core state":
  test "uninitialized state defaults and first change materializes it":
    let base = createTempDir("jump-state-", "")
    defer: removeDir(base)
    let paths = StatePaths(enabledDir: base / "enabled",
      lockFile: base / ".lock", trustedUid: getuid())
    let initial = readEnabledState(paths)
    check not initial.initialized
    check initial.enabled == @["serviceHandler"]
    enableCore(paths, "systemd")
    let current = readEnabledState(paths)
    check current.initialized
    check current.enabled == @["serviceHandler", "systemd"]
    disableCore(paths, "serviceHandler")
    check readEnabledState(paths).enabled == @["systemd"]
    expect StateError: disableCore(paths, "systemd")

  test "invalid markers invalidate the complete state":
    let base = createTempDir("jump-bad-state-", "")
    defer: removeDir(base)
    let enabled = base / "enabled"; privateDir(enabled)
    writeFile(enabled / "bad.marker", "")
    let paths = StatePaths(enabledDir: enabled,
      lockFile: base / ".lock", trustedUid: getuid())
    expect StateError: discard readEnabledState(paths)

  test "invariant callback runs before publication":
    let base = createTempDir("jump-invariant-", "")
    defer: removeDir(base)
    let paths = StatePaths(enabledDir: base / "enabled",
      lockFile: base / ".lock", trustedUid: getuid())
    proc reject(names: seq[string]) =
      raise newException(ValueError, "delegation target disabled")
    expect ValueError: enableCore(paths, "delegate", reject)
    check not dirExists(paths.enabledDir)
