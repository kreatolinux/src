## Jumpstart core manifest loading and static validation (specification §§10-13).
import std/[options, os, posix, sets, strutils, tables]
import ../../../kongue/[ast, manifest as kongueManifest]
import ./[modes, types]
import jumpstartcore/[errors, names, registry, registry_types, verified_file]

type
  ManifestError* = object of CoreError
    ## A manifest validation failure. `code` is `ecManifest` for parse and
    ## validation errors, `ecVersion` for an unimplemented `manifest_version`
    ## or an incompatible `jumpstart` range (§23), and `ecLayout` for a
    ## referenced path that escapes the core directory (§8.3).
    path*, field*: string
    line*: int

  Version* = object
    major*, minor*, patch*: int
  VersionComparator* = object
    operator*: string
    version*: Version
  VersionRange* = object
    comparators*: seq[VersionComparator]

  BackendKind* = enum bkCustom, bkExec, bkDelegate, bkUnsupported, bkNative
  ExecMode* = enum emOneshot, emPersistent

  ResolvedOption* = enum
    ## Options whose effective value may come from a default in the spec.
    roSandbox, roUser, roWritablePaths, roNetwork, roEnvironment,
    roWorkingDirectory, roArguments, roMode, roOperation

  CommonOptions* = object
    timeoutMs*: int64
    timeout*: string              ## duration as written in the manifest
    hasSandbox*: bool
    sandbox*: bool
    user*: string
    writablePaths*: seq[string]
    network*: bool
    environment*: OrderedTable[string, string]
    workingDirectory*: string

  OperationEntry* = object
    name*, description*: string
    backend*: BackendKind
    common*: CommonOptions
    handler*: string
    executable*: string
    arguments*: seq[string]
    execMode*: ExecMode
    delegateCore*, delegateOperation*: string
    defaulted*: set[ResolvedOption] ## options filled from §13 defaults
    line*: int

  Supervisor* = object
    executable*: string
    arguments*: seq[string]
    readyTimeoutMs*: int64
    readyTimeout*: string
    user*, workingDirectory*: string
    environment*: OrderedTable[string, string]
    defaulted*: set[ResolvedOption]

  CoreManifest* = object
    path*, directory*: string
    manifestVersion*: int
    name*, description*, coreVersion*, version*, jumpstart*, account*: string
    accountDefaulted*: bool
    jumpstartRange*: VersionRange
    modes*: set[CoreMode]
    subsystems*: seq[string]
    activation*: ActivationStrategy
    hasSupervisor*: bool
    supervisor*: Supervisor
    operations*: seq[OperationEntry]
    parsed*: ParsedScript
    referencedPaths*: seq[string]

  ResolvedOp* = object
    name*, description*: string
    backend*: BackendKind
    timeoutMs*: int64
    timeout*: string
    sandbox*: bool
    user*: string          ## system mode: run-as account; "" in user mode
    effectiveUser*: string ## the account the operation runs as (§7.4.3)
    writablePaths*: seq[string]
    network*: bool
    environment*: OrderedTable[string, string]
    workingDirectory*: string
    handler*, executable*: string
    arguments*: seq[string]
    execMode*: ExecMode
    delegateCore*, delegateOperation*: string
    defaulted*: set[ResolvedOption]

const
  TopFields = ["manifest_version", "name", "description", "core_version",
    "version", "jumpstart", "modes", "account", "subsystems", "activation",
    "supervisor", "supported_ops"]
  CommonOptionKeys = ["timeout", "sandbox", "user", "writable_paths", "network",
    "environment", "working_directory"]
  ## Fixed system-mode per-core directory roots (§7.2, §19.1).
  SystemStateRoot = "/var/lib/jumpstart/cores"
  SystemRuntimeRoot = "/run/jumpstart/cores"

proc raiseManifest(code: CoreErrorCode; path, field, reason: string;
                   line: int) {.noreturn.} =
  var message = path
  if line > 0: message.add(":" & $line)
  if field.len > 0: message.add(": " & field)
  message.add(": " & reason)
  var e = newException(ManifestError, message)
  e.code = code; e.message = message
  e.path = path; e.field = field; e.line = line
  raise e

proc fail(path, field, reason: string; line = 0) {.noreturn.} =
  raiseManifest(ecManifest, path, field, reason, line)

proc item(v: HeaderValue; key: string): HeaderValue =
  if v != nil and v.kind == hvMap:
    for x in v.mapVal:
      if x.key == key: return x.value

proc lineOf(v: HeaderValue; key: string): int =
  if v != nil and v.kind == hvMap:
    for x in v.mapVal:
      if x.key == key: return x.line

proc expect(v: HeaderValue; kind: HeaderValueKind; path, field: string;
            line = 0): HeaderValue =
  if v == nil: fail(path, field, "required field is missing", line)
  # `key:` without a nested block is an empty list or mapping (kongue(5)).
  if v.emptyBlock and kind in {hvList, hvMap}: return HeaderValue(kind: kind, line: v.line)
  if v.kind != kind: fail(path, field, "wrong value type", v.line)
  v

proc missingLine(v: HeaderValue; topLevel: bool): int =
  ## A missing key has no line of its own; inside a nested mapping the
  ## mapping's first line is the closest location. Top-level has none.
  if topLevel or v == nil: 0 else: v.line

proc strField(v: HeaderValue; key, path, field: string; required = true;
              default = ""; topLevel = false): string =
  let x = item(v, key)
  if x == nil:
    if required: fail(path, field, "required field is missing", missingLine(v, topLevel))
    return default
  expect(x, hvString, path, field).stringVal

proc checkKeys(v: HeaderValue; allowed: openArray[string]; path, field: string) =
  let m = expect(v, hvMap, path, field)
  for x in m.mapVal:
    let name = if field.len == 0: x.key else: field & "." & x.key
    if x.key notin allowed: fail(path, name, "unknown field", x.line)

proc strings(v: HeaderValue; path, field: string): seq[string] =
  let list = expect(v, hvList, path, field)
  for i, x in list.listVal:
    if x.kind != hvString: fail(path, field & "[" & $i & "]", "expected string", x.line)
    result.add x.stringVal

proc parseVersion*(text: string): Version =
  let p = text.split('.')
  if p.len != 3: raise newException(ValueError, "expected MAJOR.MINOR.PATCH")
  for i, s in p:
    if s.len == 0 or (s.len > 1 and s[0] == '0') or not s.allCharsInSet({'0'..'9'}):
      raise newException(ValueError, "invalid version component")
    try:
      let n = parseInt(s)
      case i
      of 0: result.major = n
      of 1: result.minor = n
      else: result.patch = n
    except ValueError: raise newException(ValueError, "version component is out of range")

proc cmp(a, b: Version): int =
  result = system.cmp(a.major, b.major)
  if result == 0: result = system.cmp(a.minor, b.minor)
  if result == 0: result = system.cmp(a.patch, b.patch)

proc parseRangeVersion(text: string): Version =
  let p = text.split('.')
  if p.len != 3: raise newException(ValueError, "expected MAJOR.MINOR.PATCH")
  for i, part in p:
    if part.len == 0 or not part.allCharsInSet({'0'..'9'}):
      raise newException(ValueError, "invalid version component")
    try:
      let n = parseInt(part)
      case i
      of 0: result.major = n
      of 1: result.minor = n
      else: result.patch = n
    except ValueError: raise newException(ValueError, "version component is out of range")

proc parseVersionRange*(text: string): VersionRange =
  if text.len == 0 or text != text.strip:
    raise newException(ValueError, "empty or padded version range")
  let pieces = text.split(',')
  for i, raw in pieces:
    if i > 0 and (raw.len == 0 or raw[0] != ' ' or
        (raw.len > 1 and raw[1] == ' ')):
      raise newException(ValueError, "a comma must be followed by one space")
    let part = if i == 0: raw else: raw[1..^1]
    var op = ""
    for candidate in [">=", "<=", ">", "<", "="]:
      if part.startsWith(candidate): op = candidate; break
    if op.len == 0: raise newException(ValueError, "comparator is required")
    let verText = part[op.len..^1]
    if verText.len == 0 or verText != verText.strip:
      raise newException(ValueError, "invalid comparator spacing")
    result.comparators.add VersionComparator(operator: op,
      version: parseRangeVersion(verText))

proc contains*(r: VersionRange; version: Version): bool =
  for c in r.comparators:
    let n = cmp(version, c.version)
    case c.operator
    of "=":
      if n != 0: return false
    of ">":
      if n <= 0: return false
    of ">=":
      if n < 0: return false
    of "<":
      if n >= 0: return false
    of "<=":
      if n > 0: return false
    else: return false
  true

proc runningVersionNumber*(jumpstartVersion: string): string =
  ## §23.2: Jumpstart's version is `jumpstartVersion` without its
  ## `jumpstart v` prefix. Accepts either form and validates the result.
  result = jumpstartVersion
  result.removePrefix("jumpstart v")
  discard parseVersion(result)

proc parseDuration*(text: string): int64 =
  var suffix = ""
  for s in ["ms", "s", "m", "h"]:
    if text.endsWith(s): suffix = s; break
  if suffix.len == 0: raise newException(ValueError, "duration unit must be ms, s, m, or h")
  let digits = text[0 ..< text.len - suffix.len]
  if digits.len == 0 or not digits.allCharsInSet({'0'..'9'}):
    raise newException(ValueError, "duration must be a positive integer and unit")
  var n: int64
  try: n = parseBiggestInt(digits)
  except ValueError: raise newException(ValueError, "duration is out of range")
  if n <= 0: raise newException(ValueError, "duration must be positive")
  let multiplier = case suffix
    of "ms": 1'i64
    of "s": 1000'i64
    of "m": 60_000'i64
    else: 3_600_000'i64
  if n > 86_400_000 div multiplier: raise newException(ValueError, "duration exceeds 24h")
  n * multiplier

proc validEnvironmentName(s: string): bool =
  if s.len == 0 or s.startsWith("JUMPSTART_") or s[0] notin {'A'..'Z', '_'}: return false
  for c in s:
    if c notin {'A'..'Z', '0'..'9', '_'}: return false
  true

proc containedRelative(path: string): bool =
  if path.len == 0 or path.isAbsolute: return false
  var depth = 0
  for p in path.split({'/', '\\'}):
    if p.len == 0 or p == ".": continue
    if p == "..":
      if depth == 0: return false
      dec depth
    else: inc depth
  true

proc executablePath(m: var CoreManifest; rel, field: string; line: int) =
  if not containedRelative(rel):
    # §8.3: a referenced path that escapes the core directory is E_LAYOUT.
    raiseManifest(ecLayout, m.path, field, "path escapes the core directory", line)
  if ".." in rel.split({'/', '\\'}) or not rel.startsWith("bin/") or rel.len <= 4:
    fail(m.path, field, "executable must be a contained path under bin/", line)
  let full = m.directory / rel
  var st: Stat
  if lstat(full.cstring, st) != 0 or S_ISLNK(st.st_mode) or not S_ISREG(st.st_mode):
    fail(m.path, field, "executable does not exist or is not a regular file", line)
  if (st.st_mode and Mode(S_IXUSR)) == 0:
    fail(m.path, field, "owner execute bit is not set", line)
  if rel notin m.referencedPaths: m.referencedPaths.add rel

proc parseEnvironment(v: HeaderValue; path, field: string): OrderedTable[string,string] =
  let env = expect(v, hvMap, path, field)
  for x in env.mapVal:
    if not validEnvironmentName(x.key): fail(path, field & "." & x.key, "invalid environment variable", x.line)
    if x.value.kind != hvString: fail(path, field & "." & x.key, "expected string", x.line)
    result[x.key] = x.value.stringVal

proc within(path, root: string): bool =
  ## True if `path` is `root` or lies beneath it (both normalized, absolute).
  root == "/" or path == root or path.startsWith(root & "/")

proc homeDirectories(): seq[string] =
  ## Home directories for the §13.1 system-mode `writable_paths` rule: the
  ## conventional `/home` and `/root`, plus the password-database home of
  ## root and of every regular (UID >= 1000, not nobody) account.
  result = @["/home", "/root"]
  setpwent()
  while true:
    let pw = getpwent()
    if pw == nil: break
    let uid = int(pw.pw_uid)
    if (uid == 0 or (uid >= 1000 and uid != 65534)) and pw.pw_dir != nil:
      let dir = normalizedPath($pw.pw_dir)
      if dir.isAbsolute and dir != "/" and dir notin result: result.add dir
  endpwent()

proc validateSystemWritablePath(m: CoreManifest; path, field: string; line: int) =
  ## §13.1: in system mode, `writable_paths` MUST NOT name a path under a home
  ## directory or under another core's per-core directories. A path that
  ## contains such a directory (such as `/var` or `/`) would expose it too,
  ## and is rejected for the same reason.
  let p = normalizedPath(path)
  for home in homeDirectories():
    if p.within(home) or home.within(p):
      fail(m.path, field, "must not name a path under a home directory: " & path, line)
  for root in [SystemStateRoot, SystemRuntimeRoot]:
    let own = root / m.name
    if p.within(own): continue
    if p.within(root) or root.within(p):
      fail(m.path, field, "must not name another core's per-core directory: " & path, line)

proc sandboxWritable(m: CoreManifest; opts: CommonOptions): seq[string] =
  ## Paths that are writable inside the sandbox and known statically (§13.8):
  ## `writable_paths`, the private `/tmp`, and, for a system-only core, its
  ## fixed per-core state and runtime directories.
  for p in opts.writablePaths: result.add normalizedPath(p)
  result.add "/tmp"
  if m.modes == {cmSystem}:
    result.add SystemStateRoot / m.name
    result.add SystemRuntimeRoot / m.name

proc commonOptions(v: HeaderValue; m: CoreManifest; field: string;
                   defaulted: var set[ResolvedOption]): CommonOptions =
  result.workingDirectory = "/"
  result.user = m.account
  let timeout = item(v, "timeout")
  if timeout != nil:
    if timeout.kind != hvString: fail(m.path, field & ".timeout", "expected duration string", timeout.line)
    try: result.timeoutMs = parseDuration(timeout.stringVal)
    except ValueError as e: fail(m.path, field & ".timeout", e.msg, timeout.line)
    result.timeout = timeout.stringVal
  let sandbox = item(v, "sandbox")
  if sandbox != nil:
    if sandbox.kind != hvBool: fail(m.path, field & ".sandbox", "expected boolean", sandbox.line)
    result.hasSandbox = true; result.sandbox = sandbox.boolVal
  else: defaulted.incl roSandbox
  let user = item(v, "user")
  if user != nil:
    if user.kind != hvString: fail(m.path, field & ".user", "expected string", user.line)
    result.user = user.stringVal
    if cmSystem in m.modes and result.user != "root" and result.user != m.account:
      fail(m.path, field & ".user", "must be root or the manifest account", user.line)
  else: defaulted.incl roUser
  let wp = item(v, "writable_paths")
  if wp != nil:
    result.writablePaths = strings(wp, m.path, field & ".writable_paths")
    let list = expect(wp, hvList, m.path, field & ".writable_paths")
    for i, p in result.writablePaths:
      let f = field & ".writable_paths[" & $i & "]"
      let line = list.listVal[i].line
      if not p.isAbsolute: fail(m.path, f, "paths must be absolute", line)
      if cmSystem in m.modes: validateSystemWritablePath(m, p, f, line)
  else: defaulted.incl roWritablePaths
  let network = item(v, "network")
  if network != nil:
    if network.kind != hvBool: fail(m.path, field & ".network", "expected boolean", network.line)
    result.network = network.boolVal
  else: defaulted.incl roNetwork
  let env = item(v, "environment")
  if env != nil: result.environment = parseEnvironment(env, m.path, field & ".environment")
  else: defaulted.incl roEnvironment
  let wd = item(v, "working_directory")
  if wd != nil:
    if wd.kind != hvString: fail(m.path, field & ".working_directory", "expected string", wd.line)
    result.workingDirectory = wd.stringVal
    if not result.workingDirectory.isAbsolute:
      fail(m.path, field & ".working_directory", "must be absolute", wd.line)
  else: defaulted.incl roWorkingDirectory
  if wp != nil and not (result.hasSandbox and result.sandbox):
    fail(m.path, field & ".writable_paths", "valid only with sandbox: true", wp.line)
  if network != nil and not (result.hasSandbox and result.sandbox):
    fail(m.path, field & ".network", "valid only with sandbox: true", network.line)
  # §13.1: under sandbox: true an explicit working_directory MUST be within a
  # writable path. The default "/" is accepted as the specification's own
  # default (Appendix B uses it with sandbox: true).
  if result.sandbox and wd != nil:
    let dir = normalizedPath(result.workingDirectory)
    var writable = false
    for p in sandboxWritable(m, result):
      if dir.within(p) and p != "/": writable = true
    if not writable:
      fail(m.path, field & ".working_directory",
        "sandbox working directory must be within a writable path", wd.line)

proc functionKey(fn: AstNode): string =
  if fn.kind == nkCustomFunc: fn.customFuncName
  elif fn.funcQualifier.len == 0: fn.funcName
  else: fn.funcName & " " & fn.funcQualifier

proc storedKey(fn: AstNode): string =
  ## The name a Kongue call statement uses (`name_qualifier`).
  if fn.kind == nkCustomFunc: fn.customFuncName
  elif fn.funcQualifier.len == 0: fn.funcName
  else: fn.funcName & "_" & fn.funcQualifier

proc allFunctions(parsed: ParsedScript): seq[AstNode] =
  result = parsed.functions & parsed.customFuncs

proc functionNames(parsed: ParsedScript): HashSet[string] =
  for fn in allFunctions(parsed): result.incl functionKey(fn)

proc bodyOf(fn: AstNode): seq[AstNode] =
  if fn.kind == nkCustomFunc: fn.customFuncBody else: fn.funcBody

proc callTable(parsed: ParsedScript): Table[string, seq[AstNode]] =
  ## Bodies keyed by every name that reaches them: the exact key used by
  ## handler bindings and the stored key used by call statements.
  for fn in allFunctions(parsed):
    result[functionKey(fn)] = bodyOf(fn)
    result[storedKey(fn)] = bodyOf(fn)

proc calls(nodes: seq[AstNode]; into: var seq[string]) =
  for n in nodes:
    case n.kind
    of nkFuncCall: into.add n.callName
    of nkIf: calls(n.thenBranch, into); calls(n.elseBranch, into)
    of nkFor: calls(n.forBody, into)
    of nkBlock: calls(n.blockBody, into)
    else: discard

proc execExpression(text: string): bool =
  ## True when `text` contains an `${exec…}` interpolation (§16.4). Spaces
  ## after `${` are allowed by the interpolation syntax, so skip them.
  var at = 0
  while true:
    at = text.find("${", at)
    if at < 0: return false
    var i = at + 2
    while i < text.len and text[i] in {' ', '\t'}: inc i
    if text.continuesWith("exec", i):
      let after = i + 4
      if after >= text.len or not (text[after].isAlphaNumeric or text[after] in {'_', '-'}):
        return true
    at += 2

proc anyExec(texts: openArray[string]): bool =
  for t in texts:
    if execExpression(t): return true

proc hasExec(nodes: seq[AstNode]; funcs: Table[string, seq[AstNode]];
             visiting: var HashSet[string]): bool =
  ## §16.4: `exec` as a command, or `${exec(…)}` in any expression position:
  ## every string a statement carries is scanned, not just the statement
  ## kinds that can hold an expression today.
  for n in nodes:
    case n.kind
    of nkExec: return true
    of nkVarManip:
      if n.baseVar == "exec" or n.baseVar.execExpression: return true
      for meth in n.methods:
        if meth.name == "exec" or anyExec(meth.args): return true
      if execExpression(n.indexExpr): return true
    of nkFuncCall:
      if n.callName == "exec" or anyExec(n.callArgs): return true
      if n.callName in funcs and n.callName notin visiting:
        visiting.incl(n.callName)
        if hasExec(funcs[n.callName], funcs, visiting): return true
    of nkIf:
      if execExpression(n.condition): return true
      if hasExec(n.thenBranch, funcs, visiting) or hasExec(n.elseBranch, funcs, visiting): return true
    of nkFor:
      if execExpression(n.iterList) or anyExec(n.iterListLiteral): return true
      if hasExec(n.forBody, funcs, visiting): return true
    of nkBlock:
      if hasExec(n.blockBody, funcs, visiting): return true
    of nkPrint:
      if execExpression(n.printText): return true
    of nkCd:
      if execExpression(n.cdPath): return true
    of nkEnv:
      if execExpression(n.envValue): return true
    of nkLocal:
      if execExpression(n.localValue): return true
    of nkGlobal:
      if execExpression(n.globalValue): return true
    of nkWrite:
      if execExpression(n.writePath) or execExpression(n.writeContent): return true
    of nkAppend:
      if execExpression(n.appendPath) or execExpression(n.appendContent): return true
    of nkMacro:
      if n.macroName == "exec" or anyExec(n.macroArgs): return true
    of nkVariable:
      if execExpression(n.varValue): return true
    of nkListVariable:
      if anyExec(n.listItems): return true
    of nkObject:
      for prop in n.objectProperties:
        if execExpression(prop.value): return true
    of nkVarRef:
      if execExpression(n.refName): return true
    else: discard

proc validateNoExec(m: CoreManifest; handler, field: string; line: int) =
  let funcs = callTable(m.parsed)
  var visiting = initHashSet[string](); visiting.incl(handler)
  if handler in funcs and hasExec(funcs[handler], funcs, visiting):
    fail(m.path, field, "custom handler can reach an exec command", line)

proc parseHandler(funcs: HeaderValue; m: CoreManifest; base: string;
                  entryLine: int): string =
  ## §13.2: a list of single-key mappings binding roles to functions. Version
  ## 1 defines exactly one role, `handler`, which MUST be bound.
  let list = expect(funcs, hvList, m.path, base & ".functions")
  for i, binding in list.listVal:
    let f = base & ".functions[" & $i & "]"
    if binding.kind != hvMap or binding.mapVal.len != 1:
      fail(m.path, f, "must be a single-key mapping", binding.line)
    let entry = binding.mapVal[0]
    if entry.key != "handler": fail(m.path, f & "." & entry.key, "unknown role", entry.line)
    if result.len > 0: fail(m.path, f & ".handler", "duplicate handler binding", entry.line)
    if entry.value.kind != hvString: fail(m.path, f & ".handler", "wrong value type", entry.line)
    result = entry.value.stringVal
    if result.len == 0: fail(m.path, f & ".handler", "must name a function", entry.line)
  if result.len == 0:
    fail(m.path, base & ".functions", "the handler role must be bound",
      if list.line > 0: list.line else: entryLine)

proc parseOperation(v: HeaderValue; index: int; m: var CoreManifest;
                    nativeAllowed: bool): OperationEntry =
  let base = "supported_ops[" & $index & "]"
  if v.kind != hvMap: fail(m.path, base, "operation entry must be a mapping", v.line)
  checkKeys(v, ["name", "backend", "options", "functions", "description"], m.path, base)
  result.line = v.line
  result.name = strField(v, "name", m.path, base & ".name")
  let nameLine = lineOf(v, "name")
  result.description = strField(v, "description", m.path, base & ".description", false)
  if not validOperationName(result.name): fail(m.path, base & ".name", "invalid operation name", nameLine)
  if names.isReservedSubsystem(operationSubsystem(result.name)):
    fail(m.path, base & ".name", "reserved subsystem: " & result.name, nameLine)
  let found = findOperation(m.manifestVersion, result.name)
  if found.isNone: fail(m.path, base & ".name", "operation is not in the version 1 registry", nameLine)
  let backend = strField(v, "backend", m.path, base & ".backend")
  let backendLine = lineOf(v, "backend")
  case backend
  of "custom": result.backend = bkCustom
  of "exec": result.backend = bkExec
  of "delegate": result.backend = bkDelegate
  of "unsupported": result.backend = bkUnsupported
  of "native":
    if not nativeAllowed: fail(m.path, base & ".backend", "native is reserved for serviceHandler", backendLine)
    result.backend = bkNative
  else: fail(m.path, base & ".backend", "unknown backend", backendLine)
  let opts = item(v, "options")
  let funcs = item(v, "functions")
  case result.backend
  of bkUnsupported, bkNative:
    if opts != nil: fail(m.path, base & ".options", "backend accepts neither options nor functions", lineOf(v, "options"))
    if funcs != nil: fail(m.path, base & ".functions", "backend accepts neither options nor functions", lineOf(v, "functions"))
  of bkDelegate:
    if funcs != nil: fail(m.path, base & ".functions", "functions is valid only for custom", lineOf(v, "functions"))
    if opts == nil: fail(m.path, base & ".options", "required field is missing", v.line)
    checkKeys(opts, ["core", "operation"], m.path, base & ".options")
    let o = expect(opts, hvMap, m.path, base & ".options")
    result.delegateCore = strField(o, "core", m.path, base & ".options.core")
    if not validCoreName(result.delegateCore, extension = false) or result.delegateCore == m.name:
      fail(m.path, base & ".options.core", "invalid delegation target", lineOf(o, "core"))
    if item(o, "operation") == nil: result.defaulted.incl roOperation
    result.delegateOperation = strField(o, "operation", m.path, base & ".options.operation", false, result.name)
    let a = operationSubsystem(result.name); let b = operationSubsystem(result.delegateOperation)
    if a != b or findOperation(m.manifestVersion, result.delegateOperation).isNone:
      fail(m.path, base & ".options.operation", "delegated operation must be known and in the same subsystem",
        if lineOf(o, "operation") > 0: lineOf(o, "operation") else: o.line)
  of bkCustom, bkExec:
    if opts == nil: fail(m.path, base & ".options", "required field is missing", v.line)
    if result.backend == bkCustom:
      checkKeys(opts, CommonOptionKeys, m.path, base & ".options")
    else:
      checkKeys(opts, @CommonOptionKeys & @["executable", "arguments", "mode"], m.path, base & ".options")
    let o = expect(opts, hvMap, m.path, base & ".options")
    result.common = commonOptions(o, m, base & ".options", result.defaulted)
    if result.common.timeoutMs == 0: fail(m.path, base & ".options.timeout", "required field is missing", o.line)
    if result.backend == bkCustom:
      if funcs == nil: fail(m.path, base & ".functions", "required field is missing", v.line)
      let funcsLine = lineOf(v, "functions")
      result.handler = parseHandler(funcs, m, base, funcsLine)
      if result.handler in ["init", "shutdown"]:
        fail(m.path, base & ".functions[0].handler", "init and shutdown cannot be handlers", funcsLine)
      if result.handler notin functionNames(m.parsed):
        fail(m.path, base & ".functions[0].handler", "handler function is not defined", funcsLine)
      validateNoExec(m, result.handler, base & ".functions[0].handler", funcsLine)
    else:
      if funcs != nil: fail(m.path, base & ".functions", "functions is valid only for custom", lineOf(v, "functions"))
      result.executable = strField(o, "executable", m.path, base & ".options.executable")
      executablePath(m, result.executable, base & ".options.executable", lineOf(o, "executable"))
      let args = item(o, "arguments")
      if args != nil: result.arguments = strings(args, m.path, base & ".options.arguments")
      else: result.defaulted.incl roArguments
      if item(o, "mode") == nil: result.defaulted.incl roMode
      let mode = strField(o, "mode", m.path, base & ".options.mode", false, "oneshot")
      case mode
      of "oneshot": result.execMode = emOneshot
      of "persistent": result.execMode = emPersistent
      else: fail(m.path, base & ".options.mode", "must be oneshot or persistent", lineOf(o, "mode"))
      if result.name.startsWith("core.") and result.execMode == emPersistent:
        fail(m.path, base & ".options.mode", "core operations cannot use persistent mode", lineOf(o, "mode"))
    let cls = found.get.operationClass
    let sandboxRequired = cls in {ocReadOnly, ocStreaming} and
      (result.backend == bkCustom or result.execMode == emOneshot)
    if sandboxRequired:
      if not result.common.hasSandbox or not result.common.sandbox:
        fail(m.path, base & ".options.sandbox", "sandbox is required and must be true",
          if lineOf(o, "sandbox") > 0: lineOf(o, "sandbox") else: o.line)
    elif result.common.hasSandbox:
      fail(m.path, base & ".options.sandbox", "sandbox must be absent for this operation", lineOf(o, "sandbox"))

proc parseSupervisor(v: HeaderValue; m: var CoreManifest; keyLine: int): Supervisor =
  let s = expect(v, hvMap, m.path, "supervisor")
  let line = if s.line > 0: s.line else: keyLine
  checkKeys(s, ["executable", "arguments", "ready_timeout", "user", "environment", "working_directory"], m.path, "supervisor")
  result.executable = strField(s, "executable", m.path, "supervisor.executable")
  executablePath(m, result.executable, "supervisor.executable",
    if lineOf(s, "executable") > 0: lineOf(s, "executable") else: line)
  let args = item(s, "arguments")
  if args != nil: result.arguments = strings(args, m.path, "supervisor.arguments")
  else: result.defaulted.incl roArguments
  result.readyTimeout = strField(s, "ready_timeout", m.path, "supervisor.ready_timeout")
  try: result.readyTimeoutMs = parseDuration(result.readyTimeout)
  except ValueError as e: fail(m.path, "supervisor.ready_timeout", e.msg, lineOf(s, "ready_timeout"))
  if item(s, "user") == nil: result.defaulted.incl roUser
  result.user = strField(s, "user", m.path, "supervisor.user", false, m.account)
  if cmSystem in m.modes and result.user != "root" and result.user != m.account:
    fail(m.path, "supervisor.user", "must be root or the manifest account", lineOf(s, "user"))
  if item(s, "working_directory") == nil: result.defaulted.incl roWorkingDirectory
  result.workingDirectory = strField(s, "working_directory", m.path, "supervisor.working_directory", false, "/")
  if not result.workingDirectory.isAbsolute:
    fail(m.path, "supervisor.working_directory", "must be absolute", lineOf(s, "working_directory"))
  let env = item(s, "environment")
  if env != nil: result.environment = parseEnvironment(env, m.path, "supervisor.environment")
  else: result.defaulted.incl roEnvironment

proc validateCompleteness*(m: CoreManifest; opsLine = 0) =
  ## §11.3 and §11.5. `opsLine` is the line of the `supported_ops` key, used
  ## for errors about operations that are missing (and so have no line).
  var declared = initHashSet[string]()
  for op in m.operations:
    if op.name in declared: fail(m.path, "supported_ops", "duplicate operation " & op.name, op.line)
    declared.incl(op.name)
    if operationSubsystem(op.name) notin m.subsystems:
      fail(m.path, "supported_ops", "operation belongs to an unclaimed subsystem: " & op.name, op.line)
  for sub in m.subsystems:
    for spec in operationsForSubsystem(m.manifestVersion, sub):
      if spec.name notin declared:
        fail(m.path, "supported_ops", "missing required operation " & spec.name, opsLine)
  var unitAddressed = false
  for sub in m.subsystems:
    if isUnitAddressedSubsystem(sub):
      unitAddressed = true
      if "unit" notin m.subsystems: fail(m.path, "subsystems", sub & " requires unit")
      let status = sub & ".status"
      for op in m.operations:
        if op.name == status and op.backend == bkUnsupported:
          fail(m.path, "supported_ops", status & " must be supported", op.line)
  if unitAddressed:
    for required in ["unit.list", "unit.resolve"]:
      for op in m.operations:
        if op.name == required and op.backend == bkUnsupported:
          fail(m.path, "supported_ops", required & " must be supported", op.line)
    for op in m.operations:
      if op.name in ["unit.activate", "unit.deactivate"]:
        if m.activation == asCore and op.backend == bkUnsupported:
          fail(m.path, "activation", op.name & " must be supported for core activation", op.line)
        if m.activation == asPerUnit and op.backend != bkUnsupported:
          fail(m.path, "activation", op.name & " must be unsupported for per-unit activation", op.line)

proc validatePersistent(m: CoreManifest) =
  var seen = initTable[string, OperationEntry]()
  for op in m.operations:
    if op.backend == bkExec and op.execMode == emPersistent:
      if op.executable in seen:
        let old = seen[op.executable]
        if op.arguments != old.arguments or op.common.user != old.common.user or
           op.common.environment != old.common.environment or
           op.common.workingDirectory != old.common.workingDirectory:
          fail(m.path, "supported_ops", "persistent adapter options differ for " & op.executable, op.line)
      else: seen[op.executable] = op

proc loadManifest*(path, expectedName, runningVersion: string;
                   nativeAllowed = false;
                   trustedOwner = -1): CoreManifest =
  ## Statically validates `path` (§10.6). `runningVersion` is the running
  ## Jumpstart version, as `jumpstartVersion` or its bare `MAJOR.MINOR.PATCH`
  ## form (§23.2); there is no default. The manifest is read through a
  ## verified descriptor (§8.3): `O_NOFOLLOW`, then owner, mode, and file type
  ## re-checked with `fstat`, failing with `E_PERMISSION`. `trustedOwner` is
  ## the uid owning the core root besides root; -1 means the effective user,
  ## which is the trusted owner for both daemons.
  let running = parseVersion(runningVersionNumber(runningVersion))
  result.path = path; result.directory = parentDir(path)
  var source: string
  try: source = readVerifiedFile(path, if trustedOwner < 0: geteuid() else: Uid(trustedOwner))
  except CoreError as e:
    raiseManifest(e.code, path, "", e.msg, 0)
  try: result.parsed = parseManifest(source)
  except ManifestParseError as e: fail(path, "", e.msg, e.line)
  except CatchableError as e: fail(path, "", e.msg)
  let h = result.parsed.manifestHeader
  # manifest_version is checked before anything else so that a manifest
  # written for a later version fails with E_VERSION, not with the unknown
  # fields that version may have added (§23.1).
  let mv = expect(item(h, "manifest_version"), hvInt, path, "manifest_version")
  if mv.intVal != CurrentManifestVersion:
    raiseManifest(ecVersion, path, "manifest_version",
      "unsupported manifest version " & $mv.intVal, mv.line)
  result.manifestVersion = int(mv.intVal)
  checkKeys(h, TopFields, path, "")
  result.name = strField(h, "name", path, "name", topLevel = true)
  if result.name != expectedName: fail(path, "name", "does not match core directory", lineOf(h, "name"))
  if not validCoreName(result.name, extension = not nativeAllowed): fail(path, "name", "invalid core name", lineOf(h, "name"))
  result.description = strField(h, "description", path, "description", false)
  if result.description.len > 200 or '\n' in result.description or '\r' in result.description:
    fail(path, "description", "must be one line and at most 200 bytes", lineOf(h, "description"))
  result.coreVersion = strField(h, "core_version", path, "core_version", topLevel = true)
  try: discard parseVersion(result.coreVersion)
  except ValueError as e: fail(path, "core_version", e.msg, lineOf(h, "core_version"))
  result.version = strField(h, "version", path, "version", topLevel = true)
  if result.version.len == 0 or result.version.len > 64: fail(path, "version", "must be 1 to 64 bytes", lineOf(h, "version"))
  result.jumpstart = strField(h, "jumpstart", path, "jumpstart", topLevel = true)
  try: result.jumpstartRange = parseVersionRange(result.jumpstart)
  except ValueError as e: fail(path, "jumpstart", e.msg, lineOf(h, "jumpstart"))
  if not result.jumpstartRange.contains(running):
    raiseManifest(ecVersion, path, "jumpstart", "running Jumpstart " &
      runningVersionNumber(runningVersion) & " is outside the supported range",
      lineOf(h, "jumpstart"))
  result.accountDefaulted = item(h, "account") == nil
  result.account = strField(h, "account", path, "account", false, "root")
  if result.account.len == 0: fail(path, "account", "must not be empty", lineOf(h, "account"))
  let modesValue = expect(item(h, "modes"), hvList, path, "modes")
  let modeValues = strings(modesValue, path, "modes")
  if modeValues.len == 0: fail(path, "modes", "must not be empty", lineOf(h, "modes"))
  for i, x in modeValues:
    let line = modesValue.listVal[i].line
    let mode = case x
      of "system": cmSystem
      of "user": cmUser
      else: fail(path, "modes[" & $i & "]", "unknown mode " & x, line)
    if mode in result.modes: fail(path, "modes[" & $i & "]", "duplicate mode " & x, line)
    result.modes.incl(mode)
  let subsValue = expect(item(h, "subsystems"), hvList, path, "subsystems")
  result.subsystems = strings(subsValue, path, "subsystems")
  var subs = initHashSet[string]()
  for i, sub in result.subsystems:
    let line = subsValue.listVal[i].line
    let field = "subsystems[" & $i & "]"
    if sub in subs: fail(path, field, "duplicate subsystem " & sub, line)
    subs.incl(sub)
    if names.isReservedSubsystem(sub): fail(path, field, "reserved subsystem " & sub, line)
    if not knownSubsystem(result.manifestVersion, sub): fail(path, field, "unknown subsystem " & sub, line)
  let activation = item(h, "activation")
  var unitAddressed = false
  for sub in result.subsystems: unitAddressed = unitAddressed or isUnitAddressedSubsystem(sub)
  if unitAddressed:
    for sub in result.subsystems:
      if isUnitAddressedSubsystem(sub) and "unit" notin result.subsystems:
        fail(path, "subsystems", sub & " requires unit", lineOf(h, "subsystems"))
    if activation == nil: fail(path, "activation", "required for unit-addressed subsystems")
    let value = expect(activation, hvString, path, "activation").stringVal
    if value == "core": result.activation = asCore
    elif value == "per-unit": result.activation = asPerUnit
    else: fail(path, "activation", "must be core or per-unit", activation.line)
  elif activation != nil: fail(path, "activation", "is valid only with a unit-addressed subsystem", activation.line)
  let supervisor = item(h, "supervisor")
  if supervisor != nil:
    result.hasSupervisor = true
    result.supervisor = parseSupervisor(supervisor, result, lineOf(h, "supervisor"))
  let opsLine = lineOf(h, "supported_ops")
  let ops = expect(item(h, "supported_ops"), hvList, path, "supported_ops")
  if result.subsystems.len == 0 and ops.listVal.len != 0:
    fail(path, "subsystems", "may be empty only with no operations", lineOf(h, "subsystems"))
  for i, op in ops.listVal: result.operations.add parseOperation(op, i, result, nativeAllowed)
  var initCount, shutdownCount = 0
  var initLine, shutdownLine = 0
  for fn in result.parsed.functions:
    if fn.funcName == "init" and fn.funcQualifier.len == 0:
      inc initCount
      if initCount == 2: initLine = fn.line
    if fn.funcName == "shutdown" and fn.funcQualifier.len == 0:
      inc shutdownCount
      if shutdownCount == 2: shutdownLine = fn.line
  if initCount != 1: fail(path, "init", "exactly one init function is required", initLine)
  if shutdownCount > 1: fail(path, "shutdown", "at most one shutdown function is allowed", shutdownLine)
  validateCompleteness(result, opsLine)
  validatePersistent(result)

proc unreferencedFunctionWarnings*(m: CoreManifest): seq[string] =
  ## §10.5: a function that is not `init`, `shutdown`, a handler binding, or
  ## called from another function SHOULD produce a warning in
  ## `jumpctl cores check` (§21.12). Each warning names the manifest path,
  ## the function's line, and the function.
  var referenced = initHashSet[string]()
  for op in m.operations:
    if op.handler.len > 0: referenced.incl op.handler
  for fn in allFunctions(m.parsed):
    var called: seq[string]
    calls(bodyOf(fn), called)
    for name in called:
      if name != storedKey(fn) and name != functionKey(fn): referenced.incl name
  for fn in allFunctions(m.parsed):
    let key = functionKey(fn)
    if fn.kind == nkFunction and fn.funcQualifier.len == 0 and
        fn.funcName in ["init", "shutdown"]: continue
    if key in referenced or storedKey(fn) in referenced: continue
    var location = m.path
    if fn.line > 0: location.add(":" & $fn.line)
    result.add location & ": function '" & key & "' is never referenced"

proc resolveOps*(m: CoreManifest; mode: CoreMode; daemonUser: string): seq[ResolvedOp] =
  ## The fully resolved operation table in registry order (§1.1, §21.11).
  ## In user mode every operation runs as the daemon's user (§7.4.3), given
  ## as `daemonUser`; `user` is left empty there because it is ignored.
  if mode notin m.modes: raise newException(ValueError, "manifest does not support requested mode")
  for spec in registry(m.manifestVersion):
    for op in m.operations:
      if op.name == spec.name:
        var r = ResolvedOp(name: op.name, description: op.description, backend: op.backend,
          timeoutMs: op.common.timeoutMs, timeout: op.common.timeout,
          sandbox: op.common.sandbox,
          writablePaths: op.common.writablePaths, network: op.common.network,
          environment: op.common.environment, workingDirectory: op.common.workingDirectory,
          handler: op.handler, executable: op.executable, arguments: op.arguments,
          execMode: op.execMode, delegateCore: op.delegateCore,
          delegateOperation: op.delegateOperation, defaulted: op.defaulted)
        if mode == cmUser:
          r.user = ""
          r.effectiveUser = daemonUser
          r.defaulted.excl roUser
        else:
          r.user = op.common.user
          r.effectiveUser = op.common.user
        result.add r

proc resolveOps*(m: CoreManifest; mode: CoreMode): seq[ResolvedOp] =
  ## Compatibility form for dispatch: the effective user-mode account is not
  ## needed there (it is the daemon's own credentials).
  resolveOps(m, mode, "")

proc operation*(m: CoreManifest; name: string): Option[OperationEntry] =
  for op in m.operations:
    if op.name == name: return some(op)
  none(OperationEntry)

# ---------------------------------------------------------------------------
# `jumpctl cores show` formatting (§21.11). Pure: no I/O.

proc backendName(kind: BackendKind): string =
  case kind
  of bkCustom: "custom"
  of bkExec: "exec"
  of bkDelegate: "delegate"
  of bkUnsupported: "unsupported"
  of bkNative: "native"

proc execModeName(mode: ExecMode): string =
  if mode == emPersistent: "persistent" else: "oneshot"

proc oneLine(s: string): string =
  s.multiReplace(("\\", "\\\\"), ("\n", "\\n"), ("\r", "\\r"))

proc quoted(s: string): string = "\"" & s.multiReplace(("\\", "\\\\"), ("\"", "\\\""),
  ("\n", "\\n"), ("\r", "\\r"), ("\t", "\\t")) & "\""

proc listText(values: seq[string]): string =
  var parts: seq[string]
  for v in values: parts.add quoted(v)
  "[" & parts.join(", ") & "]"

proc envText(env: OrderedTable[string, string]): string =
  var parts: seq[string]
  for k, v in env: parts.add quoted(k) & ": " & quoted(v)
  "{" & parts.join(", ") & "}"

proc optionLine(indent, key, value: string; defaulted: bool): string =
  result = indent & key & ": " & value
  if defaulted: result.add " (default)"

proc operationDetail(backend: BackendKind; handler, executable: string;
                     mode: ExecMode; delegateCore, delegateOperation: string): string =
  case backend
  of bkCustom: "handler=" & handler
  of bkExec: executable & " (" & execModeName(mode) & ")"
  of bkDelegate: "core=" & delegateCore & " operation=" & delegateOperation
  of bkUnsupported, bkNative: ""

proc operationLine(name: string; backend: BackendKind; detail, description: string): string =
  result = ("  " & name.alignLeft(16) & " " & backendName(backend).alignLeft(12) &
    " " & detail).strip(leading = false)
  if description.len > 0: result.add "  # " & oneLine(description)

proc resolvedOptionLines(op: ResolvedOp): seq[string] =
  const ind = "    "
  let d = op.defaulted
  case op.backend
  of bkUnsupported, bkNative: discard
  of bkDelegate:
    result.add optionLine(ind, "core", op.delegateCore, false)
    result.add optionLine(ind, "operation", op.delegateOperation, roOperation in d)
  of bkCustom, bkExec:
    if op.backend == bkExec:
      result.add optionLine(ind, "executable", op.executable, false)
      result.add optionLine(ind, "arguments", listText(op.arguments), roArguments in d)
      result.add optionLine(ind, "mode", execModeName(op.execMode), roMode in d)
    result.add optionLine(ind, "timeout", op.timeout, false)
    result.add optionLine(ind, "sandbox", $op.sandbox, roSandbox in d)
    result.add optionLine(ind, "user", op.effectiveUser, roUser in d)
    result.add optionLine(ind, "writable_paths", listText(op.writablePaths), roWritablePaths in d)
    result.add optionLine(ind, "network", $op.network, roNetwork in d)
    result.add optionLine(ind, "environment", envText(op.environment), roEnvironment in d)
    result.add optionLine(ind, "working_directory", op.workingDirectory, roWorkingDirectory in d)

proc activationName(kind: ActivationStrategy): string =
  case kind
  of asNone: ""
  of asCore: "core"
  of asPerUnit: "per-unit"
  of asNative: "core"

proc formatShow*(m: CoreManifest; mode: CoreMode; enabled: string;
                 resolved: bool; daemonUser = ""): seq[string] =
  ## Lines printed by `jumpctl cores show` (§21.11), without trailing
  ## newlines. `enabled` is the text of the `enabled:` line ("yes"/"no").
  ## With `resolved`, every option is printed with its effective value in
  ## `mode`, and each value taken from a default is marked `(default)`. In
  ## user mode `daemonUser` is the effective user of every operation.
  result.add "name: " & m.name
  result.add "core_version: " & m.coreVersion
  result.add "version: " & m.version
  result.add "jumpstart: " & m.jumpstart
  var modeNames: seq[string]
  if cmSystem in m.modes: modeNames.add "system"
  if cmUser in m.modes: modeNames.add "user"
  result.add "modes: " & modeNames.join(" ")
  result.add optionLine("", "account", m.account, resolved and m.accountDefaulted)
  if m.activation != asNone: result.add "activation: " & activationName(m.activation)
  if m.hasSupervisor:
    result.add "supervisor: " & m.supervisor.executable
    if resolved:
      let s = m.supervisor
      let user = if mode == cmUser: daemonUser else: s.user
      result.add optionLine("  ", "arguments", listText(s.arguments), roArguments in s.defaulted)
      result.add optionLine("  ", "ready_timeout", s.readyTimeout, false)
      result.add optionLine("  ", "user", user, mode == cmSystem and roUser in s.defaulted)
      result.add optionLine("  ", "environment", envText(s.environment), roEnvironment in s.defaulted)
      result.add optionLine("  ", "working_directory", s.workingDirectory, roWorkingDirectory in s.defaulted)
  result.add "enabled: " & enabled
  result.add ("subsystems: " & m.subsystems.join(" ")).strip(leading = false)
  result.add "operations:"
  if resolved:
    for op in resolveOps(m, mode, daemonUser):
      result.add operationLine(op.name, op.backend, operationDetail(op.backend,
        op.handler, op.executable, op.execMode, op.delegateCore,
        op.delegateOperation), op.description)
      result.add resolvedOptionLines(op)
  else:
    for spec in registry(m.manifestVersion):
      for op in m.operations:
        if op.name == spec.name:
          result.add operationLine(op.name, op.backend, operationDetail(op.backend,
            op.handler, op.executable, op.execMode, op.delegateCore,
            op.delegateOperation), op.description)
