## Discovery and naming (jumpstart-cores §§6, 8, 27.1).
import std/[os, posix, sequtils, strutils, tables, tempfiles, unittest]
import ../../../../jumpstart/cores/manifest/discovery
import jumpstartcore/errors

let me = getuid()
const otherUid = Uid(4242)

proc privateDir(path: string) =
  createDir(path)
  setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})

proc newBase(prefix: string): string =
  ## Temporary roots live under the system temp dir (§27), never in $HOME.
  result = createTempDir(prefix, "", getTempDir())
  privateDir(result)

proc writeManifest(dir, name: string; modes = "system user"; delegates = "") =
  writeFile(dir / "init.kg", name & "\n" & modes & "\n" & delegates)
  setFilePermissions(dir / "init.kg", {fpUserRead, fpUserWrite})

proc addCore(root, name: string; modes = "system user"; delegates = "") =
  privateDir(root / name)
  writeManifest(root / name, name, modes, delegates)

proc inspector(path: string): ManifestInfo =
  let lines = readFile(path).split('\n')
  result.name = lines[0]
  if lines.len > 1:
    for word in lines[1].splitWhitespace:
      if word == "system": result.modes.incl cmSystem
      if word == "user": result.modes.incl cmUser
  if lines.len > 2: result.delegationTargets = lines[2].splitWhitespace

proc testOptions(base: string; owners = initTable[string, Uid]();
                 modes = initTable[string, Mode]()): DiscoveryOptions =
  ## The system root's trusted owner is root (§8.3); tests run unprivileged,
  ## so the fixture's owner stands in for it. Proper ancestors of the
  ## temporary base stand in for a secure installation prefix: Linux /tmp is
  ## world-writable (sticky), which §8.3 would otherwise reject. Everything at
  ## or below the base is checked with its real metadata unless overridden.
  let lexical = normalizedPath(base)
  let real = expandFilename(base)
  let fakeOwners = owners
  let fakeModes = modes
  DiscoveryOptions(systemOwner: me, lstat: proc(path: string; st: var Stat): cint =
    result = posix.lstat(path.cstring, st)
    if result != 0: return
    let p = normalizedPath(path)
    if p == "/" or lexical.startsWith(p & "/") or real.startsWith(p & "/"):
      st.st_mode = Mode(int(st.st_mode) and not 0o022)
    if p in fakeOwners: st.st_uid = fakeOwners[p]
    if p in fakeModes: st.st_mode = fakeModes[p])

proc sysRoot(path: string): CoreRoot = CoreRoot(path: path)
proc userRoot(path: string; uid = me): CoreRoot =
  CoreRoot(path: path, trustedUid: uid, isUserRoot: true)

proc names(found: DiscoveryResult): seq[string] = found.cores.mapIt(it.name)
proc codeOf(found: DiscoveryResult; name: string): DiscoveryCode =
  for r in found.rejected:
    if r.name == name: return r.code
  raise newException(KeyError, "not rejected: " & name)

proc rootError(body: proc()): CoreErrorCode =
  try: body()
  except CoreError as e: return e.code
  raise newException(AssertionDefect, "discovery did not fail")

suite "discovery: roots and ordering":
  test "an absent root yields only serviceHandler":
    let base = newBase("jump-disc-")
    defer: removeDir(base)
    let opts = testOptions(base)
    check discoverCores(cmSystem, [sysRoot(base / "absent")], inspector, opts).names == @["serviceHandler"]
    let got = discoverCores(cmUser, [sysRoot(base / "a"), userRoot(base / "b")], inspector, opts)
    check got.names == @["serviceHandler"]
    check got.rejected.len == 0

  test "arbitrary names, native first, byte order per root, system before user":
    let base = newBase("jump-disc-")
    defer: removeDir(base)
    let sys = base / "sys"; let usr = base / "usr"
    privateDir(sys); privateDir(usr)
    for name in ["zeta", "Alpha", "my-weird_Core9"]: addCore(sys, name)
    for name in ["beta", "Aardvark"]: addCore(usr, name, "user")
    let got = discoverCores(cmUser, [sysRoot(sys), userRoot(usr)], inspector, testOptions(base))
    check got.names == @["serviceHandler", "Alpha", "my-weird_Core9", "zeta", "Aardvark", "beta"]
    check got.cores[1].sourceRoot == sys
    check got.cores[4].sourceRoot == usr

  test "installing and removing an extension changes results":
    let base = newBase("jump-disc-")
    defer: removeDir(base)
    let root = base / "cores"; privateDir(root)
    let opts = testOptions(base)
    check discoverCores(cmSystem, [sysRoot(root)], inspector, opts).names == @["serviceHandler"]
    addCore(root, "fresh")
    check discoverCores(cmSystem, [sysRoot(root)], inspector, opts).names == @["serviceHandler", "fresh"]
    removeDir(root / "fresh")
    check discoverCores(cmSystem, [sysRoot(root)], inspector, opts).names == @["serviceHandler"]

  test "discovery is deterministic":
    let base = newBase("jump-disc-")
    defer: removeDir(base)
    let root = base / "cores"; privateDir(root)
    for name in ["c", "a", "b"]: addCore(root, name)
    writeFile(root / "file", "")
    privateDir(root / "2bad")
    let opts = testOptions(base)
    let first = discoverCores(cmSystem, [sysRoot(root)], inspector, opts)
    let second = discoverCores(cmSystem, [sysRoot(root)], inspector, opts)
    check first == second
    check first.rejected.mapIt(it.name) == @["2bad", "file"]

  test "delegation targets are recorded for state invariants":
    let base = newBase("jump-disc-")
    defer: removeDir(base)
    let root = base / "cores"; privateDir(root)
    addCore(root, "front", delegates = "zz back back")
    let got = discoverCores(cmSystem, [sysRoot(root)], inspector, testOptions(base))
    check got.cores[1].delegationTargets == @["back", "zz"]

suite "discovery: names and layout":
  test "invalid and reserved names are rejected with E_NAME":
    let base = newBase("jump-disc-")
    defer: removeDir(base)
    let root = base / "cores"; privateDir(root)
    for name in ["2bad", "has.dot", "serviceHandler", "jumpstart", "native", "all", "none", "a".repeat(65)]:
      addCore(root, name)
    addCore(root, "good")
    let got = discoverCores(cmSystem, [sysRoot(root)], inspector, testOptions(base))
    check got.names == @["serviceHandler", "good"]
    check got.rejected.len == 8
    check got.rejected.allIt(it.code == E_NAME)

  test "non-directories and symlinks anywhere are rejected with E_LAYOUT":
    let base = newBase("jump-disc-")
    defer: removeDir(base)
    let root = base / "cores"; privateDir(root)
    writeFile(root / "plainfile", "")
    addCore(root, "target")
    createSymlink(root / "target", root / "linkedcore")
    addCore(root, "deep")
    privateDir(root / "deep" / "share"); privateDir(root / "deep" / "share" / "x")
    createSymlink("/etc", root / "deep" / "share" / "x" / "evil")
    addCore(root, "linkedmanifest")
    removeFile(root / "linkedmanifest" / "init.kg")
    createSymlink(root / "target" / "init.kg", root / "linkedmanifest" / "init.kg")
    addCore(root, "fifo")
    privateDir(root / "fifo" / "lib")
    check mkfifo(cstring(root / "fifo" / "lib" / "pipe"), Mode(0o600)) == 0
    let got = discoverCores(cmSystem, [sysRoot(root)], inspector, testOptions(base))
    check got.names == @["serviceHandler", "target"]
    for name in ["plainfile", "linkedcore", "deep", "linkedmanifest", "fifo"]:
      check got.codeOf(name) == E_LAYOUT

  test "unexpected top-level entries are rejected":
    let base = newBase("jump-disc-")
    defer: removeDir(base)
    let root = base / "cores"; privateDir(root)
    addCore(root, "extra"); privateDir(root / "extra" / "etc")
    addCore(root, "binfile"); writeFile(root / "binfile" / "bin", "")
    setFilePermissions(root / "binfile" / "bin", {fpUserRead, fpUserWrite})
    addCore(root, "ok")
    for sub in ["bin", "lib", "share"]: privateDir(root / "ok" / sub)
    let got = discoverCores(cmSystem, [sysRoot(root)], inspector, testOptions(base))
    check got.names == @["serviceHandler", "ok"]
    check got.codeOf("extra") == E_LAYOUT
    check got.codeOf("binfile") == E_LAYOUT

  test "manifest problems are E_MANIFEST, version problems E_VERSION":
    let base = newBase("jump-disc-")
    defer: removeDir(base)
    let root = base / "cores"; privateDir(root)
    privateDir(root / "nomanifest")
    privateDir(root / "dirmanifest"); privateDir(root / "dirmanifest" / "init.kg")
    privateDir(root / "misnamed"); writeManifest(root / "misnamed", "other")
    for name in ["broken", "coded", "flagged", "escape"]: addCore(root, name)
    proc inspect(path: string): ManifestInfo =
      result = inspector(path)
      case result.name
      of "broken": raise newException(ValueError, "parse error")
      of "coded": raise newCoreError(ecVersion, "requires Jumpstart >= 9")
      of "flagged": result.incompatibleVersion = true
      of "escape": result.referencedPaths = @["bin/../../outside"]
      else: discard
    let got = discoverCores(cmSystem, [sysRoot(root)], inspect, testOptions(base))
    check got.names == @["serviceHandler"]
    check got.codeOf("nomanifest") == E_MANIFEST
    check got.codeOf("dirmanifest") == E_MANIFEST
    check got.codeOf("misnamed") == E_MANIFEST
    check got.codeOf("broken") == E_MANIFEST
    check got.codeOf("coded") == E_VERSION
    check got.codeOf("flagged") == E_VERSION
    check got.codeOf("escape") == E_LAYOUT
    check coreErrorCode(E_VERSION) == ecVersion

suite "discovery: modes and shadowing":
  test "system extensions without the mode are hidden, not errors":
    let base = newBase("jump-disc-")
    defer: removeDir(base)
    let root = base / "cores"; privateDir(root)
    addCore(root, "sysonly", "system"); addCore(root, "both")
    let user = discoverCores(cmUser, [sysRoot(root)], inspector, testOptions(base))
    check user.names == @["serviceHandler", "both"]
    check user.rejected.len == 0
    addCore(root, "useronly", "user")
    check discoverCores(cmSystem, [sysRoot(root)], inspector, testOptions(base)).names ==
      @["serviceHandler", "both", "sysonly"]

  test "user-root cores must support user mode":
    let base = newBase("jump-disc-")
    defer: removeDir(base)
    let usr = base / "usr"; privateDir(usr)
    addCore(usr, "nouser", "system")
    let got = discoverCores(cmUser, [userRoot(usr)], inspector, testOptions(base))
    check got.codeOf("nouser") == E_MANIFEST

  test "user cores shadowing any system extension are rejected with E_NAME":
    let base = newBase("jump-disc-")
    defer: removeDir(base)
    let sys = base / "sys"; let usr = base / "usr"
    privateDir(sys); privateDir(usr)
    addCore(sys, "valid"); addCore(sys, "hidden", "system")
    privateDir(sys / "invalid")  # rejected system extension: no init.kg
    writeFile(sys / "notadir", "")
    for name in ["valid", "hidden", "invalid", "notadir", "mine"]: addCore(usr, name, "user")
    let got = discoverCores(cmUser, [sysRoot(sys), userRoot(usr)], inspector, testOptions(base))
    check got.names == @["serviceHandler", "valid", "mine"]
    for name in ["hidden", "invalid", "notadir"]:
      check got.rejected.filterIt(it.name == name and it.path.startsWith(usr)).mapIt(it.code) == @[E_NAME]
    check got.rejected.filterIt(it.name == "valid").mapIt(it.code) == @[E_NAME]

suite "discovery: ownership and permissions":
  test "wrong owners and group/world-writable entries in the tree are rejected":
    let base = newBase("jump-disc-")
    defer: removeDir(base)
    let root = base / "cores"; privateDir(root)
    addCore(root, "grouped"); privateDir(root / "grouped" / "lib")
    writeFile(root / "grouped" / "lib" / "data", "")
    setFilePermissions(root / "grouped" / "lib" / "data", {fpUserRead, fpUserWrite, fpGroupWrite})
    addCore(root, "worlddir"); privateDir(root / "worlddir" / "share")
    setFilePermissions(root / "worlddir" / "share", {fpUserRead, fpUserWrite, fpUserExec, fpOthersWrite})
    addCore(root, "owned"); privateDir(root / "owned" / "bin")
    writeFile(root / "owned" / "bin" / "tool", "")
    setFilePermissions(root / "owned" / "bin" / "tool", {fpUserRead, fpUserWrite, fpUserExec})
    addCore(root, "rootowned")
    var owners = initTable[string, Uid]()
    owners[normalizedPath(root / "owned" / "bin" / "tool")] = otherUid
    owners[normalizedPath(root / "rootowned" / "init.kg")] = Uid(0)
    let got = discoverCores(cmSystem, [sysRoot(root)], inspector, testOptions(base, owners))
    check got.names == @["serviceHandler", "rootowned"]
    for name in ["grouped", "worlddir", "owned"]: check got.codeOf(name) == E_PERMISSION

  test "user-root entries must be owned by the user or root":
    let base = newBase("jump-disc-")
    defer: removeDir(base)
    let usr = base / "usr"; privateDir(usr)
    addCore(usr, "mine", "user"); addCore(usr, "byroot", "user"); addCore(usr, "foreign", "user")
    var owners = initTable[string, Uid]()
    owners[normalizedPath(usr / "byroot" / "init.kg")] = Uid(0)
    owners[normalizedPath(usr / "foreign" / "init.kg")] = otherUid
    let got = discoverCores(cmUser, [userRoot(usr)], inspector, testOptions(base, owners))
    check got.names == @["serviceHandler", "byroot", "mine"]
    check got.codeOf("foreign") == E_PERMISSION

  test "insecure roots fail discovery with E_PERMISSION":
    let base = newBase("jump-disc-")
    defer: removeDir(base)
    let root = base / "cores"; privateDir(root); addCore(root, "x")
    setFilePermissions(root, {fpUserRead, fpUserWrite, fpUserExec, fpGroupWrite})
    check rootError(proc() = discard discoverCores(cmSystem, [sysRoot(root)], inspector,
      testOptions(base))) == ecPermission
    privateDir(root)
    var owners = initTable[string, Uid]()
    owners[normalizedPath(root)] = otherUid
    check rootError(proc() = discard discoverCores(cmSystem, [sysRoot(root)], inspector,
      testOptions(base, owners))) == ecPermission

  test "insecure parents fail discovery with E_PERMISSION":
    let base = newBase("jump-disc-")
    defer: removeDir(base)
    let parent = base / "parent"; privateDir(parent)
    let root = parent / "cores"; privateDir(root); addCore(root, "x")
    setFilePermissions(parent, {fpUserRead, fpUserWrite, fpUserExec, fpOthersWrite})
    check rootError(proc() = discard discoverCores(cmSystem, [sysRoot(root)], inspector,
      testOptions(base))) == ecPermission
    privateDir(parent)
    var owners = initTable[string, Uid]()
    owners[normalizedPath(parent)] = otherUid
    check rootError(proc() = discard discoverCores(cmUser, [userRoot(root)], inspector,
      testOptions(base, owners))) == ecPermission
    check discoverCores(cmSystem, [sysRoot(root)], inspector, testOptions(base)).names ==
      @["serviceHandler", "x"]

  test "the system root's trusted owner is root, whatever trustedUid says":
    if me == Uid(0):
      skip()  # every fixture is root-owned when running as root
    else:
      let base = newBase("jump-disc-")
      defer: removeDir(base)
      let root = base / "cores"; privateDir(root); addCore(root, "x")
      var opts = testOptions(base)
      opts.systemOwner = Uid(0)
      check rootError(proc() = discard discoverCores(cmUser,
        [CoreRoot(path: root, trustedUid: me)], inspector, opts)) == ecPermission
      # The same tree is fine as the user's own root.
      check discoverCores(cmUser, [userRoot(root)], inspector, opts).names == @["serviceHandler", "x"]
      check rootError(proc() = discard discoverCores(cmUser,
        [userRoot(root, otherUid)], inspector, opts)) == ecPermission

  test "a symlinked root is rejected but symlinked parents are followed":
    let base = newBase("jump-disc-")
    defer: removeDir(base)
    let real = base / "real"; privateDir(real)
    privateDir(real / "cores"); addCore(real / "cores", "x")
    createSymlink(real / "cores", base / "linkroot")
    check rootError(proc() = discard discoverCores(cmSystem, [sysRoot(base / "linkroot")],
      inspector, testOptions(base))) == ecLayout
    createSymlink(real, base / "linkparent")
    check discoverCores(cmSystem, [sysRoot(base / "linkparent" / "cores")], inspector,
      testOptions(base)).names == @["serviceHandler", "x"]
    # The symlink target is checked too.
    setFilePermissions(real, {fpUserRead, fpUserWrite, fpUserExec, fpGroupWrite})
    check rootError(proc() = discard discoverCores(cmSystem, [sysRoot(base / "linkparent" / "cores")],
      inspector, testOptions(base))) == ecPermission

  test "a root that is not a directory fails discovery":
    let base = newBase("jump-disc-")
    defer: removeDir(base)
    writeFile(base / "cores", "")
    setFilePermissions(base / "cores", {fpUserRead, fpUserWrite})
    check rootError(proc() = discard discoverCores(cmSystem, [sysRoot(base / "cores")],
      inspector, testOptions(base))) == ecLayout

  test "an unreadable root fails discovery; unreadable subtrees are rejected":
    if me == Uid(0):
      skip()  # root bypasses directory permissions
    else:
      let base = newBase("jump-disc-")
      defer:
        for path in [base / "cores", base / "ok" / "locked" / "lib"]:
          if dirExists(path): privateDir(path)
        removeDir(base)
      let root = base / "cores"; privateDir(root); addCore(root, "x")
      setFilePermissions(root, {fpUserExec})
      check rootError(proc() = discard discoverCores(cmSystem, [sysRoot(root)],
        inspector, testOptions(base))) == ecPermission
      let ok = base / "ok"; privateDir(ok)
      addCore(ok, "locked"); privateDir(ok / "locked" / "lib")
      writeFile(ok / "locked" / "lib" / "secret", "")
      setFilePermissions(ok / "locked" / "lib", {fpUserWrite})
      addCore(ok, "open")
      let got = discoverCores(cmSystem, [sysRoot(ok)], inspector, testOptions(base))
      check got.names == @["serviceHandler", "open"]
      check got.codeOf("locked") == E_PERMISSION
