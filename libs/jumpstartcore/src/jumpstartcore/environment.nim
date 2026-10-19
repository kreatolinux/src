## Construction of the closed environments used by core processes (§7.5,
## §16.2). This is the only environment builder for core processes: the
## spawn layer and every runtime use it. No procedure in this module reads the
## process environment or the password database; callers pass the identity.
##
## Layers, later overriding earlier ones, with exactly one entry per key in
## the result:
##
## 1. base environment (system or user mode);
## 2. user environment store (`jumpctl env`, user mode only);
## 3. the manifest `environment` of the operation or supervisor;
## 4. `JUMPSTART_*` variables, which can never be overridden.
import std/[algorithm, json, tables]
import ./coremode

type
  Environment* = Table[string, string]
  EnvPair* = tuple[key, value: string]
  EnvironmentError* = object of ValueError
  UserIdentity* = object
    ## Password-database fields of the daemon's user (user mode, §7.5).
    uid*: int
    home*, user*, logname*, shell*: string
  CoreVariables* = object
    name*, root*, stateDir*, runtimeDir*: string
    mode*: CoreMode
  OperationVariables* = object
    name*, unit*, requestId*: string
    args*: Environment

const
  SystemPath* = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    ## §7.5 system-mode base `PATH`.
  UserPath* = "/usr/local/bin:/usr/bin:/bin"
    ## §7.5 user-mode base `PATH`.
  BaseLang* = "C.UTF-8"
    ## §7.5 `LANG` in both modes.
  ProtectedUserVariables* = ["HOME", "USER", "LOGNAME", "SHELL"]
    ## §7.5/§21.9: variables the user environment store cannot set.

proc validEnvironmentName*(name: string): bool =
  ## §13.1/§21.9 key syntax: `[A-Z_][A-Z0-9_]*`.
  if name.len == 0 or name[0] notin {'A'..'Z', '_'}: return false
  for c in name:
    if c notin {'A'..'Z', '0'..'9', '_'}: return false
  true

proc isJumpstartVariable*(name: string): bool =
  name.len >= 10 and name[0 ..< 10] == "JUMPSTART_"

proc isProtectedUserVariable*(name: string): bool =
  name in ProtectedUserVariables or isJumpstartVariable(name)

proc checkValue(name, value: string) =
  if '\0' in value:
    raise newException(EnvironmentError, "NUL in environment value: " & name)

proc validateLayer(layer: Environment; userStore: bool) =
  for name, value in layer:
    if not validEnvironmentName(name):
      raise newException(EnvironmentError, "invalid environment variable: " & name)
    if isJumpstartVariable(name) or (userStore and name in ProtectedUserVariables):
      raise newException(EnvironmentError, "protected environment variable: " & name)
    checkValue(name, value)

proc canonicalRuntimeDirFor*(uid: int): string =
  ## §7.2: `RUNTIME` is `/run/user/UID` when that directory is usable.
  "/run/user/" & $uid

proc baseEnvironment*(mode: CoreMode; identity = UserIdentity();
                      runtimeDir = ""; canonicalRuntimeDir = false): Environment =
  ## `canonicalRuntimeDir` says that the caller verified `RUNTIME` is
  ## `/run/user/UID` (§7.2). Only then is `XDG_RUNTIME_DIR` set (§7.5).
  result = initTable[string, string]()
  result["LANG"] = BaseLang
  case mode
  of cmSystem:
    result["PATH"] = SystemPath
  of cmUser:
    if identity.uid <= 0 or identity.home.len == 0 or identity.user.len == 0 or
        identity.logname.len == 0 or identity.shell.len == 0:
      raise newException(EnvironmentError, "complete non-root user identity required")
    for (name, value) in [("HOME", identity.home), ("USER", identity.user),
                          ("LOGNAME", identity.logname), ("SHELL", identity.shell)]:
      checkValue(name, value)
      result[name] = value
    result["PATH"] = UserPath
    if canonicalRuntimeDir:
      if runtimeDir != canonicalRuntimeDirFor(identity.uid):
        raise newException(EnvironmentError,
          "XDG_RUNTIME_DIR is only set when RUNTIME is /run/user/UID")
      result["XDG_RUNTIME_DIR"] = runtimeDir

proc modeName*(mode: CoreMode): string =
  if mode == cmSystem: "system" else: "user"

proc coreEnvironmentVariables*(core: CoreVariables): Environment =
  ## §16.2: every process Jumpstart starts for a core.
  result = initTable[string, string]()
  result["JUMPSTART_CORE_NAME"] = core.name
  result["JUMPSTART_CORE_ROOT"] = core.root
  result["JUMPSTART_CORE_STATE_DIR"] = core.stateDir
  result["JUMPSTART_CORE_RUNTIME_DIR"] = core.runtimeDir
  result["JUMPSTART_MODE"] = modeName(core.mode)
  for name, value in result: checkValue(name, value)

proc argumentVariable*(key: string): string =
  ## §16.2 `JUMPSTART_ARG_<KEY>` with the key upper-cased.
  var upper = newString(key.len)
  for i, c in key:
    upper[i] = if c in {'a'..'z'}: chr(ord(c) - ord('a') + ord('A')) else: c
  if not validEnvironmentName(upper):
    raise newException(EnvironmentError, "invalid operation argument key: " & key)
  "JUMPSTART_ARG_" & upper

proc operationEnvironmentVariables*(op: OperationVariables): Environment =
  ## §16.2: Kongue runners and oneshot adapters handling a request.
  result = initTable[string, string]()
  result["JUMPSTART_OP"] = op.name
  result["JUMPSTART_UNIT"] = op.unit
  result["JUMPSTART_REQUEST_ID"] = op.requestId
  for key, value in op.args:
    let variable = argumentVariable(key)
    if result.hasKey(variable):
      raise newException(EnvironmentError, "operation argument name collision: " & key)
    checkValue(variable, value)
    result[variable] = value
  for name, value in result: checkValue(name, value)

proc argumentText*(value: JsonNode): string =
  ## §16.2: booleans and integers are rendered as strings.
  case value.kind
  of JString: value.getStr
  of JBool: (if value.getBool: "true" else: "false")
  of JInt: $value.getBiggestInt
  else:
    raise newException(EnvironmentError, "request arguments must be scalars")

proc operationArguments*(args: JsonNode): Environment =
  ## Request `args` object (§12) as string values.
  result = initTable[string, string]()
  if args.isNil: return
  if args.kind != JObject:
    raise newException(EnvironmentError, "request arguments must be an object")
  for key, value in args: result[key] = argumentText(value)

proc buildEnvironment*(mode: CoreMode; identity: UserIdentity;
                       runtimeDir = ""; canonicalRuntimeDir = false;
                       userStore = initTable[string, string]();
                       manifest = initTable[string, string]();
                       core: CoreVariables; operation: OperationVariables;
                       includeOperation = true): Environment =
  ## Build the four layers of §7.5. This is deliberately closed: callers
  ## cannot provide the daemon environment as an implicit base layer.
  ## `includeOperation` is false for persistent adapters and supervisors
  ## (§16.2), which receive request data only through the protocol.
  if core.mode != mode:
    raise newException(EnvironmentError, "core and environment modes differ")
  result = baseEnvironment(mode, identity, runtimeDir, canonicalRuntimeDir)
  if mode == cmUser:
    validateLayer(userStore, true)
    for key, value in userStore: result[key] = value
  elif userStore.len != 0:
    raise newException(EnvironmentError, "user environment store in system mode")
  validateLayer(manifest, false)
  for key, value in manifest: result[key] = value
  for key, value in coreEnvironmentVariables(core): result[key] = value
  if includeOperation:
    for key, value in operationEnvironmentVariables(operation): result[key] = value

proc toEnvironment*(pairs: openArray[EnvPair]): Environment =
  ## Later pairs override earlier ones.
  result = initTable[string, string]()
  for (key, value) in pairs: result[key] = value

proc toEnvPairs*(environment: Environment): seq[EnvPair] =
  ## Deterministic, duplicate-free pairs in byte order of key.
  for key, value in environment: result.add((key, value))
  result.sort(proc(a, b: EnvPair): int = cmp(a.key, b.key))

proc environmentVector*(environment: Environment): seq[string] =
  ## Stable `KEY=VALUE` representation for envp and deterministic tests.
  for (key, value) in toEnvPairs(environment): result.add(key & "=" & value)

proc buildSystemEnvironment*(manifest: openArray[EnvPair] = [];
                             jumpstart: openArray[EnvPair] = []): seq[EnvPair] =
  ## System-mode base plus optional manifest and `JUMPSTART_*` layers, for
  ## callers that do not yet build `CoreVariables`. Same rules as
  ## `buildEnvironment`: manifest keys are validated and cannot start with
  ## `JUMPSTART_`; the last layer may contain only `JUMPSTART_*` keys.
  var env = baseEnvironment(cmSystem)
  let manifestLayer = toEnvironment(manifest)
  validateLayer(manifestLayer, false)
  for key, value in manifestLayer: env[key] = value
  for (key, value) in jumpstart:
    if not isJumpstartVariable(key) or not validEnvironmentName(key):
      raise newException(EnvironmentError, "not a JUMPSTART_* variable: " & key)
    checkValue(key, value)
    env[key] = value
  toEnvPairs(env)
