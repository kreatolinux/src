import std/[algorithm, json, sequtils, strutils, tables, unittest]
import jumpstartcore/[coremode, environment]

suite "closed core environments":
  test "system base is fixed and manifest overlays it":
    var manifest = {"PATH": "/core/bin", "TOKEN": "x"}.toTable
    let core = CoreVariables(name: "demo", root: "/core", stateDir: "/state",
      runtimeDir: "/run", mode: cmSystem)
    let env = buildEnvironment(cmSystem, UserIdentity(), manifest = manifest,
      core = core, operation = OperationVariables())
    check env["PATH"] == "/core/bin"
    check env["LANG"] == "C.UTF-8"
    check env["JUMPSTART_CORE_NAME"] == "demo"
    check not env.hasKey("HOME")

  test "user layers and operation variables override in order":
    let identity = UserIdentity(uid: 42, home: "/home/a", user: "a", logname: "a", shell: "/bin/sh")
    var store = {"DISPLAY": ":1", "PATH": "/session/bin"}.toTable
    var manifest = {"DISPLAY": ":2"}.toTable
    var args = {"force": "true"}.toTable
    let core = CoreVariables(name: "demo", mode: cmUser)
    let op = OperationVariables(name: "service.start", unit: "web", requestId: "r1", args: args)
    let env = buildEnvironment(cmUser, identity, "/run/user/42", true, store, manifest, core, op)
    check env["HOME"] == "/home/a"
    check env["XDG_RUNTIME_DIR"] == "/run/user/42"
    check env["DISPLAY"] == ":2"
    check env["JUMPSTART_OP"] == "service.start"
    check env["JUMPSTART_ARG_FORCE"] == "true"

  test "protected and malformed variables fail closed":
    let identity = UserIdentity(uid: 1, home: "/h", user: "u", logname: "u", shell: "/s")
    let core = CoreVariables(mode: cmUser)
    expect EnvironmentError:
      discard buildEnvironment(cmUser, identity, userStore = {"HOME": "/evil"}.toTable, core = core, operation = OperationVariables())
    expect EnvironmentError:
      discard buildEnvironment(cmUser, identity, manifest = {"JUMPSTART_OP": "evil"}.toTable, core = core, operation = OperationVariables())
    expect EnvironmentError:
      discard buildEnvironment(cmUser, identity, manifest = {"lower": "x"}.toTable, core = core, operation = OperationVariables())

suite "environment layering (§7.5, §16.2)":
  let identity = UserIdentity(uid: 1000, home: "/home/u", user: "u", logname: "u", shell: "/bin/zsh")
  let core = CoreVariables(name: "demo", root: "/cores/demo", stateDir: "/state/demo",
    runtimeDir: "/run/user/1000/jumpstart/cores/demo", mode: cmUser)

  test "every layer overrides the previous one and envp has no duplicate keys":
    let env = buildEnvironment(cmUser, identity, "/run/user/1000", true,
      userStore = {"PATH": "/store", "DISPLAY": ":0", "LANG": "de_DE.UTF-8"}.toTable,
      manifest = {"PATH": "/manifest", "EDITOR": "vi"}.toTable,
      core = core, operation = OperationVariables(name: "log.vacuum", unit: "",
        requestId: "r9", args: operationArguments(%*{"max_size": 4096, "now": true})))
    let vector = environmentVector(env)
    var keys: seq[string]
    for entry in vector: keys.add entry.split('=', 1)[0]
    check keys.deduplicate.len == keys.len
    check keys == keys.sorted
    check env["PATH"] == "/manifest"
    check env["LANG"] == "de_DE.UTF-8"
    check env["DISPLAY"] == ":0"
    check env["SHELL"] == "/bin/zsh"
    check env["LOGNAME"] == "u"
    check env["JUMPSTART_ARG_MAX_SIZE"] == "4096"
    check env["JUMPSTART_ARG_NOW"] == "true"
    check env["JUMPSTART_UNIT"] == ""
    check env["JUMPSTART_REQUEST_ID"] == "r9"
    check env["JUMPSTART_MODE"] == "user"
    check env["JUMPSTART_CORE_RUNTIME_DIR"] == "/run/user/1000/jumpstart/cores/demo"
    check not env.hasKey("JUMPSTART_CORE")

  test "persistent processes get no request variables":
    let env = buildEnvironment(cmUser, identity, core = core,
      operation = OperationVariables(name: "service.start"), includeOperation = false)
    check not env.hasKey("JUMPSTART_OP")
    check not env.hasKey("XDG_RUNTIME_DIR")
    check env["JUMPSTART_CORE_NAME"] == "demo"

  test "XDG_RUNTIME_DIR only for /run/user/UID":
    expect EnvironmentError:
      discard baseEnvironment(cmUser, identity, "/home/u/.local/share/jumpstart/runtime", true)
    check baseEnvironment(cmUser, identity, "/run/user/1000", true)["XDG_RUNTIME_DIR"] == "/run/user/1000"

  test "store cannot set identity or JUMPSTART variables; system mode has no store":
    for key in ["HOME", "USER", "LOGNAME", "SHELL", "JUMPSTART_MODE"]:
      expect EnvironmentError:
        discard buildEnvironment(cmUser, identity, userStore = {key: "x"}.toTable,
          core = core, operation = OperationVariables())
    expect EnvironmentError:
      discard buildEnvironment(cmSystem, UserIdentity(), userStore = {"DISPLAY": ":0"}.toTable,
        core = CoreVariables(mode: cmSystem), operation = OperationVariables())
    expect EnvironmentError:
      discard operationArguments(%*{"nested": {"a": 1}})
