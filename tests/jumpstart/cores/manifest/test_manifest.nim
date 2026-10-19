import std/[options, os, posix, strutils, tempfiles, unittest]
import ../../../../jumpstart/cores/manifest/[manifest, modes, types]
import jumpstartcore/[errors, registry]

const Valid = """manifest_version: 1
name: "demo"
description: "Demo core"
core_version: "1.2.3"
version: "opaque"
jumpstart: ">=1.2.0, <2.0.0"
modes:
  - "system"
  - "user"
subsystems:
  - "core"
supported_ops:
  - name: "core.verify"
    backend: "custom"
    options:
      timeout: "10s"
      sandbox: true
      environment:
        DEMO: "yes"
    functions:
      - handler: "verify"
init {
  print "init"
}
func verify {
  print "verify"
}
"""

type Outcome = object
  ok: bool
  code: CoreErrorCode
  msg, field: string
  line: int

proc makeCore(text: string; executables: openArray[string] = ["bin/adapter"];
              plainFiles: openArray[string] = []; name = "demo"): string =
  ## Returns the init.kg path of a core directory under a fresh temp root.
  let root = createTempDir("jumpstart-manifest-", "")
  let dir = root / name
  createDir(dir / "bin")
  for exe in executables:
    writeFile(dir / exe, "#!/bin/sh\n")
    setFilePermissions(dir / exe, {fpUserRead, fpUserWrite, fpUserExec})
  for plain in plainFiles:
    writeFile(dir / plain, "data\n")
    setFilePermissions(dir / plain, {fpUserRead, fpUserWrite})
  result = dir / "init.kg"
  writeFile(result, text)

proc cleanup(path: string) = removeDir(parentDir(parentDir(path)))

proc load(text: string; version = "1.2.0"): CoreManifest =
  let path = makeCore(text)
  try: result = loadManifest(path, "demo", version)
  finally: cleanup(path)

proc outcome(text: string; executables: openArray[string] = ["bin/adapter"];
             plainFiles: openArray[string] = []): Outcome =
  let path = makeCore(text, executables, plainFiles)
  try:
    discard loadManifest(path, "demo", "1.2.0")
    result.ok = true
  except ManifestError as e:
    result = Outcome(ok: false, code: e.code, msg: e.msg, field: e.field, line: e.line)
  finally: cleanup(path)

proc rejected(text: string; needle = ""): bool =
  let o = outcome(text)
  not o.ok and o.code == ecManifest and (needle.len == 0 or needle in o.msg)

proc lineOf(text, needle: string): int =
  let lines = text.splitLines()
  for i, line in lines:
    if needle in line: return i + 1

proc opEntry(name: string; backend = "exec"; extra = ""): string =
  case backend
  of "unsupported": "  - name: \"" & name & "\"\n    backend: \"unsupported\"\n"
  else:
    "  - name: \"" & name & "\"\n    backend: \"exec\"\n    options:\n" &
      "      executable: \"bin/adapter\"\n      mode: \"persistent\"\n" &
      "      timeout: \"10s\"\n" & extra

proc unitManifest(activation = "core"; replace: openArray[(string, string)] = [];
                  drop: openArray[string] = []; extraOps = "";
                  subsystems = @["unit", "service"]; modes = "  - \"system\"\n";
                  extraTop = ""): string =
  result = "manifest_version: 1\nname: \"demo\"\ncore_version: \"0.1.0\"\n" &
    "version: \"1\"\njumpstart: \">=1.2.0, <2.0.0\"\nmodes:\n" & modes & extraTop &
    "subsystems:\n"
  for sub in subsystems: result.add "  - \"" & sub & "\"\n"
  if activation.len > 0: result.add "activation: \"" & activation & "\"\n"
  result.add "supported_ops:\n"
  for sub in subsystems:
    for spec in operationsForSubsystem(1, sub):
      if spec.name in drop: continue
      var entry = ""
      for r in replace:
        if r[0] == spec.name: entry = r[1]
      if entry.len == 0:
        entry = if activation == "per-unit" and spec.name in ["unit.activate", "unit.deactivate"]:
            opEntry(spec.name, "unsupported")
          else: opEntry(spec.name)
      result.add entry
  result.add extraOps
  result.add "init {\n  print \"init\"\n}\n"

suite "core manifest validation and resolution":
  test "versions and ranges are strict and conjunctive":
    check parseVersion("1.2.3") == Version(major: 1, minor: 2, patch: 3)
    for bad in ["1", "1.2", "01.2.3", "1.-2.3", "1.2.3.4"]:
      expect ValueError: discard parseVersion(bad)
    let r = parseVersionRange(">=1.2.0, <2.0.0")
    check r.contains(parseVersion("1.2.0"))
    check r.contains(parseVersion("1.9.9"))
    check not r.contains(parseVersion("2.0.0"))
    for bad in ["", "1.2.3", ">=1.2", ">= 1.2.3", ">=1.2.3,<2.0.0"]:
      expect ValueError: discard parseVersionRange(bad)
    check runningVersionNumber("jumpstart v1.2.0") == "1.2.0"
    check runningVersionNumber("1.2.0") == "1.2.0"
    expect ValueError: discard runningVersionNumber("jumpstart v1.2")

  test "durations enforce positive values, units, and 24 hour ceiling":
    check parseDuration("1ms") == 1
    check parseDuration("90s") == 90_000
    check parseDuration("24h") == 86_400_000
    for bad in ["0s", "1", "25h", "-1s", "1d"]:
      expect ValueError: discard parseDuration(bad)

  test "loads, fills defaults, and resolves in registry order":
    let m = load(Valid)
    check m.name == "demo"
    check m.account == "root"
    check m.accountDefaulted
    check m.activation == asNone
    check m.operations.len == 1
    check m.operations[0].common.timeoutMs == 10_000
    check m.operations[0].common.timeout == "10s"
    check m.operations[0].common.workingDirectory == "/"
    check m.operations[0].defaulted == {roUser, roWritablePaths, roNetwork, roWorkingDirectory}
    let resolved = resolveOps(m, cmUser)
    check resolved.len == 1
    check resolved[0].name == "core.verify"
    check resolved[0].sandbox
    check resolved[0].user == ""
    check resolveOps(m, cmUser, "alice")[0].effectiveUser == "alice"
    check resolveOps(m, cmSystem)[0].effectiveUser == "root"

  test "the running version is required and may carry the jumpstart prefix":
    check load(Valid, "jumpstart v1.2.0").name == "demo"
    let path = makeCore(Valid)
    try:
      expect ValueError: discard loadManifest(path, "demo", "")
    finally: cleanup(path)

suite "manifest top-level fields (27.3)":
  test "missing and malformed manifests are rejected":
    let path = makeCore(Valid)
    removeFile(path)
    try:
      expect ManifestError: discard loadManifest(path, "demo", "1.2.0")
    finally: cleanup(path)
    let o = outcome(Valid.replace("modes:\n", "modes\n"))
    check not o.ok and o.code == ecManifest and o.line == lineOf(Valid, "modes:")
    check rejected("", "header is empty")

  test "mismatched names are rejected":
    check rejected(Valid.replace("name: \"demo\"", "name: \"other\""), "does not match")

  test "each required top-level field is required":
    for key in ["name", "core_version", "version", "jumpstart"]:
      var text = ""
      for line in Valid.splitLines(keepEol = true):
        if not line.startsWith(key & ":"): text.add line
      let o = outcome(text)
      check not o.ok
      check o.field == key
      check "required field is missing" in o.msg
    let noVersion = Valid.replace("manifest_version: 1\n", "")
    check outcome(noVersion).field == "manifest_version"
    check rejected(Valid.replace("modes:\n  - \"system\"\n  - \"user\"\n", ""), "modes: required")
    check rejected(Valid.replace("subsystems:\n  - \"core\"\n", ""), "subsystems: required")
    check rejected(Valid.replace(Valid[Valid.find("supported_ops:") ..< Valid.find("init {")], ""),
      "supported_ops: required")

  test "duplicate, unknown, and wrongly typed fields are rejected":
    check rejected(Valid.replace("version: \"opaque\"", "version: \"opaque\"\nversion: \"again\""),
      "duplicate manifest key")
    check rejected(Valid.replace("description: \"Demo core\"", "mystery: \"x\""), "mystery: unknown field")
    check rejected(Valid.replace("manifest_version: 1", "manifest_version: \"1\""), "wrong value type")
    check rejected(Valid.replace("name: \"demo\"", "name: 7"), "name: wrong value type")
    check rejected(Valid.replace("description: \"Demo core\"", "description: true"), "wrong value type")
    check rejected(Valid.replace("modes:\n  - \"system\"\n  - \"user\"", "modes: \"system\""),
      "modes: wrong value type")
    check rejected(Valid.replace("  - \"user\"", "  - 3"), "expected string")
    check rejected(Valid.replace("account", "account").replace("modes:", "account: false\nmodes:"),
      "account: wrong value type")

  test "underscore qualifiers and style folding never apply to keys":
    check rejected(Valid.replace("description: \"Demo core\"", "description_extra: \"x\""),
      "description_extra: unknown field")
    check rejected(Valid.replace("core_version:", "coreVersion:"), "coreVersion: unknown field")
    check rejected(Valid.replace("core_version:", "core version:"), "invalid manifest key")
    check rejected(Valid.replace("        DEMO: \"yes\"\n", "").replace("      sandbox: true",
      "      Sandbox: true\n      sandbox: true"), "Sandbox: unknown field")

  test "description limits apply only to the top-level description":
    check rejected(Valid.replace("Demo core", 'x'.repeat(201)), "at most 200 bytes")
    let long = Valid.replace("    functions:", "    description: \"" & 'y'.repeat(500) &
      "\"\n    functions:")
    check load(long).operations[0].description.len == 500

  test "core_version must be MAJOR.MINOR.PATCH without leading zeros":
    for bad in ["1.0", "01.0.0", "v1.0.0", "1.0.0-rc1", ""]:
      check rejected(Valid.replace("core_version: \"1.2.3\"", "core_version: \"" & bad & "\""),
        "core_version")
    check load(Valid.replace("1.2.3", "0.10.0")).coreVersion == "0.10.0"

  test "version is opaque but bounded":
    check rejected(Valid.replace("version: \"opaque\"", "version: \"\""), "1 to 64 bytes")
    check rejected(Valid.replace("version: \"opaque\"", "version: \"" & 'v'.repeat(65) & "\""),
      "1 to 64 bytes")

  test "manifest_version other than 1 is E_VERSION":
    for v in ["0", "2"]:
      let o = outcome(Valid.replace("manifest_version: 1", "manifest_version: " & v))
      check not o.ok
      check o.code == ecVersion
      check o.field == "manifest_version"
      check o.line == 1
    # A later version's new fields do not mask the version error.
    let future = outcome(Valid.replace("manifest_version: 1", "manifest_version: 2\nfuture: \"x\""))
    check future.code == ecVersion

  test "jumpstart ranges: malformed is E_MANIFEST, incompatible is E_VERSION":
    let bad = outcome(Valid.replace(">=1.2.0, <2.0.0", ">=1.2"))
    check bad.code == ecManifest and bad.field == "jumpstart"
    let incompatible = outcome(Valid.replace(">=1.2.0, <2.0.0", ">=2.0.0"))
    check not incompatible.ok
    check incompatible.code == ecVersion
    check incompatible.line == lineOf(Valid, "jumpstart:")
    check "outside" in incompatible.msg
    check load(Valid.replace(">=1.2.0, <2.0.0", "=1.2.0")).name == "demo"

  test "version errors are CoreErrors carrying the code":
    let path = makeCore(Valid.replace(">=1.2.0, <2.0.0", ">=9.0.0"))
    try:
      discard loadManifest(path, "demo", "1.2.0")
      check false
    except CoreError as e:
      check e.code == ecVersion
      check errorName(e.code) == "E_VERSION"
    finally: cleanup(path)

  test "modes and subsystems are validated with line numbers":
    let unknownMode = Valid.replace("  - \"user\"", "  - \"daemon\"")
    var o = outcome(unknownMode)
    check o.field == "modes[1]" and o.line == lineOf(unknownMode, "\"daemon\"")
    let dupMode = Valid.replace("  - \"user\"", "  - \"system\"")
    o = outcome(dupMode)
    check "duplicate mode" in o.msg and o.line == 9
    check rejected(Valid.replace("modes:\n  - \"system\"\n  - \"user\"", "modes:"), "must not be empty")
    let reserved = Valid.replace("  - \"core\"\n", "  - \"core\"\n  - \"network\"\n")
    o = outcome(reserved)
    check "reserved subsystem network" in o.msg
    check o.line == lineOf(reserved, "\"network\"")
    check rejected(Valid.replace("  - \"core\"\n", "  - \"core\"\n  - \"bogus\"\n"), "unknown subsystem")
    check rejected(Valid.replace("  - \"core\"\n", "  - \"core\"\n  - \"core\"\n"), "duplicate subsystem")

  test "every reserved subsystem name is rejected":
    for name in ["boot", "device", "home", "hostname", "login", "network", "power",
                 "resolve", "scope", "slice", "sysusers", "time", "tmpfiles"]:
      check rejected(Valid.replace("  - \"core\"\n", "  - \"core\"\n  - \"" & name & "\"\n"),
        "reserved subsystem")

  test "an empty subsystems list is valid only without operations":
    let empty = "manifest_version: 1\nname: \"demo\"\ncore_version: \"0.1.0\"\n" &
      "version: \"1\"\njumpstart: \">=1.2.0\"\nmodes:\n  - \"system\"\n" &
      "subsystems:\nsupported_ops:\ninit {\n}\n"
    let m = load(empty)
    check m.subsystems.len == 0
    check m.operations.len == 0
    check rejected(Valid.replace("subsystems:\n  - \"core\"", "subsystems:"),
      "may be empty only with no operations")

  test "init is required exactly once and shutdown at most once":
    var o = outcome(Valid.replace("init {", "boot {"))
    check "exactly one init" in o.msg
    o = outcome(Valid & "init {\n}\n")
    check not o.ok and "duplicate or colliding function name 'init'" in o.msg
    check o.line == lineOf(Valid, "func verify") + 3
    o = outcome(Valid & "shutdown {\n}\nshutdown {\n}\n")
    check not o.ok and "'shutdown'" in o.msg
    check load(Valid & "shutdown {\n}\n").name == "demo"
    check rejected(Valid & "func init {\n}\n", "func init is not allowed")

  test "header text after the first function block is rejected":
    let o = outcome(Valid & "account: \"late\"\n")
    check not o.ok
    check "must precede the first function block" in o.msg
    check o.line == Valid.splitLines.len

  test "tabs are allowed in function bodies but not in header indentation":
    check load(Valid.replace("  print \"verify\"", "\tprint \"verify\"")).name == "demo"
    check rejected(Valid.replace("  - \"user\"", "\t- \"user\""), "tabs are not allowed")

suite "activation and supervisor (27.3)":
  test "activation is required exactly when a unit-addressed subsystem is claimed":
    check load(unitManifest()).activation == asCore
    check load(unitManifest("per-unit")).activation == asPerUnit
    check rejected(unitManifest(""), "activation: required")
    check rejected(unitManifest("sometimes"), "must be core or per-unit")
    check rejected(Valid.replace("supported_ops:", "activation: \"core\"\nsupported_ops:"),
      "is valid only with a unit-addressed subsystem")
    # unit alone is not unit-addressed.
    check rejected(unitManifest("core", subsystems = @["unit"]),
      "is valid only with a unit-addressed subsystem")
    check load(unitManifest("", subsystems = @["unit"])).activation == asNone

  test "unit-addressed subsystems require unit":
    check rejected(unitManifest(subsystems = @["service"]), "service requires unit")

  test "core activation needs activate/deactivate, per-unit forbids them":
    check rejected(unitManifest("core", replace = [("unit.activate",
      opEntry("unit.activate", "unsupported"))]), "must be supported for core activation")
    check rejected(unitManifest("core", replace = [("unit.deactivate",
      opEntry("unit.deactivate", "unsupported"))]), "must be supported for core activation")
    check rejected(unitManifest("per-unit", replace = [("unit.activate",
      opEntry("unit.activate"))]), "must be unsupported for per-unit activation")
    check rejected(unitManifest("per-unit", replace = [("unit.deactivate",
      opEntry("unit.deactivate"))]), "must be unsupported for per-unit activation")

  test "supervisor keys are validated":
    let sup = "supervisor:\n  executable: \"bin/adapter\"\n  ready_timeout: \"30s\"\n"
    let m = load(unitManifest(extraTop = sup))
    check m.hasSupervisor
    check m.supervisor.readyTimeoutMs == 30_000
    check m.supervisor.user == "root"
    check m.supervisor.workingDirectory == "/"
    check m.supervisor.defaulted == {roArguments, roUser, roEnvironment, roWorkingDirectory}
    check rejected(unitManifest(extraTop = sup & "  restart: \"always\"\n"), "supervisor.restart: unknown field")
    check rejected(unitManifest(extraTop = "supervisor:\n  ready_timeout: \"30s\"\n"),
      "supervisor.executable: required")
    check rejected(unitManifest(extraTop = "supervisor:\n  executable: \"bin/adapter\"\n"),
      "supervisor.ready_timeout: required")
    check rejected(unitManifest(extraTop = sup.replace("30s", "30")), "duration unit")
    check rejected(unitManifest(extraTop = sup & "  user: \"bob\"\n"), "must be root or the manifest account")
    check rejected(unitManifest(extraTop = sup & "  working_directory: \"tmp\"\n"), "must be absolute")
    check rejected(unitManifest(extraTop = sup.replace("bin/adapter", "bin/missing")), "does not exist")
    check rejected(unitManifest(extraTop = "supervisor: \"bin/adapter\"\n"), "supervisor: wrong value type")

suite "operation entries (27.4)":
  test "unknown, reserved, malformed, and duplicate operation names":
    check rejected(Valid.replace("core.verify", "core.bogus"), "not in the version 1 registry")
    check rejected(Valid.replace("core.verify", "Core.verify"), "invalid operation name")
    check rejected(Valid.replace("core.verify", "core"), "invalid operation name")
    check rejected(Valid.replace("core.verify", "core.verify.x"), "invalid operation name")
    check rejected(Valid.replace("core.verify", "network.up"), "reserved subsystem: network.up")
    let dup = Valid.replace("init {", Valid[Valid.find("  - name:") ..< Valid.find("init {")] & "init {")
    let o = outcome(dup)
    check "duplicate operation core.verify" in o.msg
    check o.line == lineOf(dup, "init {") - 9

  test "strict completeness names the missing verb":
    let text = unitManifest(drop = ["service.stop"])
    let o = outcome(text)
    check not o.ok
    check o.field == "supported_ops"
    check o.msg.endsWith("missing required operation service.stop")
    check o.line == lineOf(text, "supported_ops:")

  test "entries for an unclaimed subsystem are rejected":
    let o = outcome(unitManifest(extraOps = opEntry("mount.start")))
    check "unclaimed subsystem: mount.start" in o.msg
    check o.line > 0

  test "unit.list, unit.resolve, and status must not be unsupported":
    for name in ["unit.list", "unit.resolve", "service.status"]:
      check rejected(unitManifest(replace = [(name, opEntry(name, "unsupported"))]),
        name & " must be supported")
    # Other verbs may be unsupported.
    check load(unitManifest(replace = [("unit.translate",
      opEntry("unit.translate", "unsupported"))])).name == "demo"

  test "backends: required, optional, and forbidden keys":
    check rejected(Valid.replace("backend: \"custom\"", "backend: \"unsupported\""),
      "neither options nor functions")
    check rejected(Valid.replace("backend: \"custom\"", "backend: \"native\""), "reserved for serviceHandler")
    check rejected(Valid.replace("backend: \"custom\"", "backend: \"shell\""), "unknown backend")
    check rejected(Valid.replace("      timeout: \"10s\"\n", ""), "options.timeout: required")
    check rejected(Valid.replace("      timeout: \"10s\"", "      timeout: \"10s\"\n      mode: \"oneshot\""),
      "options.mode: unknown field")
    check rejected(Valid.replace("    options:\n      timeout: \"10s\"\n      sandbox: true\n" &
      "      environment:\n        DEMO: \"yes\"\n", ""), "options: required")
    check rejected(Valid.replace("        DEMO: \"yes\"", "        JUMPSTART_BAD: \"yes\""), "invalid environment")
    check rejected(Valid.replace("        DEMO: \"yes\"", "        lower: \"yes\""), "invalid environment")

  test "functions is valid only for custom":
    let execFns = unitManifest(replace = [("service.start", opEntry("service.start") &
      "    functions:\n      - handler: \"x\"\n")])
    check rejected(execFns, "functions is valid only for custom")
    let unsupportedFns = unitManifest(replace = [("unit.translate",
      opEntry("unit.translate", "unsupported") & "    functions:\n      - handler: \"x\"\n")])
    check rejected(unsupportedFns, "neither options nor functions")
    let delegateFns = unitManifest(replace = [("service.kill",
      "  - name: \"service.kill\"\n    backend: \"delegate\"\n    options:\n" &
      "      core: \"other\"\n    functions:\n      - handler: \"x\"\n")])
    check rejected(delegateFns, "functions is valid only for custom")

  test "handler bindings: missing, unknown roles, duplicates, and undefined":
    check rejected(Valid.replace("    functions:\n      - handler: \"verify\"\n", ""), "functions: required")
    check rejected(Valid.replace("    functions:\n      - handler: \"verify\"\n", "    functions:\n"),
      "handler role must be bound")
    check rejected(Valid.replace("      - handler: \"verify\"", "      - helper: \"verify\""), "unknown role")
    check rejected(Valid.replace("      - handler: \"verify\"",
      "      - handler: \"verify\"\n      - handler: \"verify\""), "duplicate handler binding")
    check rejected(Valid.replace("      - handler: \"verify\"",
      "      - handler: \"verify\"\n        extra: \"x\""), "single-key mapping")
    check rejected(Valid.replace("func verify {", "func missing {"), "not defined")
    check rejected(Valid.replace("handler: \"verify\"", "handler: \"init\""), "cannot be handlers")
    let qualified = Valid.replace("handler: \"verify\"", "handler: \"verify payload\"")
      .replace("func verify {", "verify payload {")
    check load(qualified).operations[0].handler == "verify payload"
    check rejected(Valid.replace("handler: \"verify\"", "handler: \"verify_payload\"")
      .replace("func verify {", "verify payload {"), "not defined")

  test "custom handlers cannot reach exec":
    check rejected(Valid.replace("  print \"verify\"", "  exec \"true\""), "reach an exec")
    check rejected(Valid.replace("  print \"verify\"", "  helper") & "func helper {\n  exec \"true\"\n}\n",
      "reach an exec")

  test "§8.3: the manifest is opened without following symlinks and re-checked":
    let path = makeCore(Valid)
    defer: cleanup(path)
    check loadManifest(path, "demo", "1.2.0").name == "demo"
    # A symlinked init.kg is refused with E_PERMISSION, even to a valid file.
    let real = parentDir(path) / "real.kg"
    moveFile(path, real)
    createSymlink(real, path)
    var failure = false
    try: discard loadManifest(path, "demo", "1.2.0")
    except ManifestError as e:
      failure = true
      check e.code == ecPermission
    check failure
    # A symlinked core directory is refused too.
    removeFile(path)
    moveFile(real, path)
    let coreDir = parentDir(path)
    let linkedDir = parentDir(coreDir) / "alias"
    createSymlink(coreDir, linkedDir)
    failure = false
    try: discard loadManifest(linkedDir / "init.kg", "demo", "1.2.0")
    except ManifestError as e:
      failure = true
      check e.code == ecPermission
    check failure
    # Writable by group or other, or owned by an untrusted uid.
    setFilePermissions(path, {fpUserRead, fpUserWrite, fpGroupWrite})
    failure = false
    try: discard loadManifest(path, "demo", "1.2.0")
    except ManifestError as e:
      failure = true
      check e.code == ecPermission
    check failure
    setFilePermissions(path, {fpUserRead, fpUserWrite})
    if getuid() != Uid(0):
      failure = false
      try: discard loadManifest(path, "demo", "1.2.0", trustedOwner = int(getuid()) + 1)
      except ManifestError as e:
        failure = true
        check e.code == ecPermission
      check failure

  test "§16.4: exec expressions in any expression position are rejected":
    # Each form hides `${exec(…)}` inside a statement the handler runs.
    for body in [
        "  print \"${exec(\\\"id\\\")}\"",
        "  local x = \"${exec(\\\"id\\\")}\"",
        "  print ${exec(\"id\")}",
        "  respond name \"${exec(\\\"id\\\").output()}\"",
        "  env X=\"${exec(\\\"id\\\")}\"",
        "  write \"/tmp/x\" \"${exec(\\\"id\\\").output()}\"",
        "  if \"${exec(\\\"id\\\").output()}\" == \"x\" {\n    print \"y\"\n  }"]:
      check rejected(Valid.replace("  print \"verify\"", body), "reach an exec")
    # Reachable through a helper function, too.
    check rejected(Valid.replace("  print \"verify\"", "  helper") &
      "func helper {\n  local x = \"${exec(\\\"id\\\")}\"\n}\n", "reach an exec")
    # spawn (command and expression forms) stays allowed in handlers, and
    # exec is still allowed in init.
    check not rejected(Valid.replace("  print \"verify\"",
      "  spawn \"/bin/true\"\n  local x = \"${spawn(\\\"/bin/true\\\").exit()}\""))
    check not rejected(Valid.replace("  print \"init\"", "  local x = \"${exec(\\\"id\\\")}\"\n  exec \"true\""))

  test "sandbox is required where it applies and rejected elsewhere":
    check rejected(Valid.replace("      sandbox: true\n", ""), "sandbox is required")
    check rejected(Valid.replace("      sandbox: true", "      sandbox: false"), "sandbox is required")
    # Mutating custom operation.
    let mutating = unitManifest(replace = [("service.start",
      "  - name: \"service.start\"\n    backend: \"custom\"\n    options:\n" &
      "      timeout: \"10s\"\n      sandbox: true\n    functions:\n      - handler: \"start\"\n")]) &
      "func start {\n  print \"start\"\n}\n"
    check rejected(mutating, "sandbox must be absent")
    check load(mutating.replace("      sandbox: true\n", "")).name == "demo"
    # Read-only operation on a persistent adapter.
    check rejected(unitManifest(replace = [("service.status",
      opEntry("service.status", extra = "      sandbox: true\n"))]), "sandbox must be absent")
    # Read-only operation on a oneshot adapter needs it.
    let oneshot = unitManifest(replace = [("unit.validate", opEntry("unit.validate")
      .replace("persistent", "oneshot"))])
    check rejected(oneshot, "sandbox is required")

  test "writable_paths and network require the sandbox":
    let unsandboxed = unitManifest(replace = [("service.start",
      opEntry("service.start", extra = "      network: true\n"))])
    check rejected(unsandboxed, "network: valid only with sandbox: true")
    let wp = unitManifest(replace = [("service.start",
      opEntry("service.start", extra = "      writable_paths:\n        - \"/srv\"\n"))])
    check rejected(wp, "writable_paths: valid only with sandbox: true")
    let ok = load(Valid.replace("      sandbox: true",
      "      sandbox: true\n      network: true\n      writable_paths:\n        - \"/srv/demo\""))
    check ok.operations[0].common.network
    check ok.operations[0].common.writablePaths == @["/srv/demo"]
    check rejected(Valid.replace("      sandbox: true",
      "      sandbox: true\n      writable_paths:\n        - \"srv\""), "must be absolute")

  test "system-mode writable_paths exclude homes and other cores' directories":
    proc wp(path: string; modes = Valid): string =
      modes.replace("      sandbox: true", "      sandbox: true\n      writable_paths:\n        - \"" & path & "\"")
    check rejected(wp("/home/alice/cache"), "home directory")
    check rejected(wp("/root"), "home directory")
    check rejected(wp("/"), "home directory")
    check rejected(wp("/var/lib/jumpstart/cores/other"), "another core's per-core directory")
    check rejected(wp("/run/jumpstart/cores/other/sub"), "another core's per-core directory")
    check rejected(wp("/var/lib/jumpstart/cores"), "another core's per-core directory")
    check rejected(wp("/var"))
    check load(wp("/var/lib/jumpstart/cores/demo/cache")).name == "demo"
    check load(wp("/run/jumpstart/cores/demo")).name == "demo"
    # User-only manifests are not subject to the system-mode rule.
    check load(wp("/home/alice/cache", Valid.replace("  - \"system\"\n", ""))).name == "demo"

  test "an explicit sandboxed working_directory must be writable":
    proc wd(dir: string; extra = ""): string =
      Valid.replace("      sandbox: true", "      sandbox: true\n      working_directory: \"" &
        dir & "\"" & extra)
    check rejected(wd("/"), "within a writable path")
    check rejected(wd("/srv"), "within a writable path")
    check rejected(wd("relative"), "must be absolute")
    check load(wd("/tmp")).operations[0].common.workingDirectory == "/tmp"
    check load(wd("/srv/demo/x", "\n      writable_paths:\n        - \"/srv/demo\"")).name == "demo"
    # The specification's default "/" stays valid (Appendix B relies on it).
    check load(Valid).operations[0].common.workingDirectory == "/"
    # Fixed per-core directories are writable for a system-only core.
    let systemOnly = wd("/var/lib/jumpstart/cores/demo").replace("  - \"user\"\n", "")
    check load(systemOnly).name == "demo"

  test "exec paths are contained, present, and executable":
    let text = unitManifest()
    check load(text).referencedPaths == @["bin/adapter"]
    var o = outcome(text.replace("bin/adapter", "lib/adapter"))
    check "under bin/" in o.msg and o.code == ecManifest
    o = outcome(text.replace("bin/adapter", "../escape"))
    check o.code == ecLayout and "escapes the core directory" in o.msg
    o = outcome(text.replace("bin/adapter", "/usr/bin/true"))
    check o.code == ecLayout
    o = outcome(text, executables = [])
    check "does not exist" in o.msg
    o = outcome(text, executables = [], plainFiles = ["bin/adapter"])
    check "owner execute bit" in o.msg

  test "persistent adapters share identical options":
    let text = unitManifest(replace = [("service.start",
      opEntry("service.start", extra = "      environment:\n        X: \"1\"\n"))])
    check rejected(text, "persistent adapter options differ for bin/adapter")
    let args = unitManifest(replace = [("service.stop",
      opEntry("service.stop", extra = "      arguments:\n        - \"--x\"\n"))])
    check rejected(args, "persistent adapter options differ")

  test "core operations cannot be persistent":
    let text = unitManifest(subsystems = @["core", "unit", "service"],
      replace = [("core.verify", opEntry("core.verify"))])
    check rejected(text, "core operations cannot use persistent mode")

  test "user must be root or account in system mode":
    let bob = unitManifest(replace = [("service.start",
      opEntry("service.start", extra = "      user: \"bob\"\n"))])
    check rejected(bob, "must be root or the manifest account")
    let account = unitManifest(extraTop = "account: \"svc\"\n")
    let m = load(account)
    check m.account == "svc" and not m.accountDefaulted
    check m.operations[0].common.user == "svc"
    let rootUser = unitManifest(extraTop = "account: \"svc\"\n", replace = [("service.start",
      opEntry("service.start", extra = "      user: \"root\"\n"))])
    check rejected(rootUser, "persistent adapter options differ")
    # Ignored, so not validated, in user mode.
    let userOnly = unitManifest(modes = "  - \"user\"\n", replace = [("service.start",
      opEntry("service.start", extra = "      user: \"bob\"\n"))])
    check rejected(userOnly, "persistent adapter options differ")
    check rejected(Valid.replace("      sandbox: true", "      sandbox: true\n      user: \"bob\""),
      "must be root or the manifest account")
    check load(Valid.replace("  - \"system\"\n", "").replace("      sandbox: true",
      "      sandbox: true\n      user: \"bob\"")).name == "demo"

  test "delegation entries are well-formed":
    let good = unitManifest(replace = [("service.kill",
      "  - name: \"service.kill\"\n    backend: \"delegate\"\n    options:\n      core: \"other\"\n")])
    let m = load(good)
    let op = m.operation("service.kill").get
    check op.delegateCore == "other"
    check op.delegateOperation == "service.kill"
    check roOperation in op.defaulted
    check rejected(good.replace("core: \"other\"", "core: \"demo\""), "invalid delegation target")
    check rejected(good.replace("core: \"other\"", "core: \"other\"\n      operation: \"unit.list\""),
      "same subsystem")
    check rejected(good.replace("core: \"other\"", "core: \"other\"\n      timeout: \"1s\""),
      "options.timeout: unknown field")

suite "show and check output (21.11, 21.12)":
  test "show prints the summary in registry order":
    let lines = formatShow(load(Valid), cmSystem, "yes", resolved = false)
    check lines == @[
      "name: demo",
      "core_version: 1.2.3",
      "version: opaque",
      "jumpstart: >=1.2.0, <2.0.0",
      "modes: system user",
      "account: root",
      "enabled: yes",
      "subsystems: core",
      "operations:",
      "  core.verify      custom       handler=verify"]

  test "show --resolved prints every option and marks defaults":
    let lines = formatShow(load(Valid), cmSystem, "no", resolved = true)
    check lines == @[
      "name: demo",
      "core_version: 1.2.3",
      "version: opaque",
      "jumpstart: >=1.2.0, <2.0.0",
      "modes: system user",
      "account: root (default)",
      "enabled: no",
      "subsystems: core",
      "operations:",
      "  core.verify      custom       handler=verify",
      "    timeout: 10s",
      "    sandbox: true",
      "    user: root (default)",
      "    writable_paths: [] (default)",
      "    network: false (default)",
      "    environment: {\"DEMO\": \"yes\"}",
      "    working_directory: / (default)"]

  test "show --resolved shows the effective user in user mode":
    let lines = formatShow(load(Valid), cmUser, "yes", resolved = true, daemonUser = "alice")
    check "    user: alice" in lines

  test "show prints activation, supervisor, exec mode, and exec defaults":
    let sup = "supervisor:\n  executable: \"bin/adapter\"\n  ready_timeout: \"30s\"\n"
    let m = load(unitManifest(extraTop = sup, replace = [("unit.translate",
      opEntry("unit.translate", "unsupported"))]))
    let plain = formatShow(m, cmSystem, "yes", resolved = false)
    check "activation: core" in plain
    check "supervisor: bin/adapter" in plain
    check "  unit.list        exec         bin/adapter (persistent)" in plain
    check "  unit.translate   unsupported" in plain
    check plain[plain.find("operations:") + 1].startsWith("  unit.list ")
    let resolved = formatShow(m, cmSystem, "yes", resolved = true)
    for line in ["  arguments: [] (default)", "  ready_timeout: 30s", "  user: root (default)",
                 "    executable: bin/adapter", "    arguments: [] (default)",
                 "    mode: persistent", "    sandbox: false (default)"]:
      check line in resolved

  test "unreferenced functions produce warnings":
    let text = Valid & "func helper {\n  print \"h\"\n}\nfunc unused {\n  helper\n}\n" &
      "shutdown {\n}\nfunc selfish {\n  selfish\n}\n"
    let path = makeCore(text)
    try:
      let warnings = unreferencedFunctionWarnings(loadManifest(path, "demo", "1.2.0"))
      check warnings.len == 2
      check warnings[0] == path & ":" & $lineOf(text, "func unused") & ": function 'unused' is never referenced"
      check "'selfish'" in warnings[1]
    finally: cleanup(path)
    check unreferencedFunctionWarnings(load(Valid)).len == 0
