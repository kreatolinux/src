import std/[strutils, tables, unittest]
import ../../kongue/kongue

suite "Kongue strict manifest parsing":
  test "recursive typed structured headers":
    let parsed = parseManifest("""
manifest_version: 1
name: "example" # trailing comment
modes:
  - "system"
supervisor:
  executable: "bin/supervisor"
  ready_timeout: "30s"
supported_ops:
  - name: "unit.resolve"
    backend: "exec"
    options:
      executable: "bin/adapter"
      mode: "persistent"
      timeout: "5s"
      network: false
      retries: 3
    functions:
      - handler: "resolve_unit"
init {
  print "ready"
}
""")
    let header = parsed.manifestHeader
    check header.kind == hvMap
    check header.getHeader("manifest_version").kind == hvInt
    check header.getHeader("manifest_version").intVal == 1
    check header.getHeader("modes").listVal[0].stringVal == "system"
    let op = header.getHeader("supported_ops").listVal[0]
    check op.kind == hvMap
    check op.getHeader("options").getHeader("network").kind == hvBool
    check not op.getHeader("options").getHeader("network").boolVal
    check op.getHeader("options").getHeader("retries").intVal == 3
    check parsed.functions.len == 1

  test "quoted list scalars may contain colons":
    let parsed = parseManifest("name: \"x\"\npaths:\n  - \"https://example.invalid/a:b\"\ninit {}\n")
    check parsed.manifestHeader.getHeader("paths").listVal[0].stringVal ==
      "https://example.invalid/a:b"

  test "duplicate keys and malformed indentation are rejected":
    expect ManifestParseError:
      discard parseManifest("name: \"one\"\nname: \"two\"\ninit {}\n")
    expect ManifestParseError:
      discard parseManifest("name: \"one\"\n  modes:\n - \"system\"\ninit {}\n")
    expect ManifestParseError:
      discard parseManifest("name:\n\t- \"one\"\ninit {}\n")
    expect ManifestParseError:
      discard parseManifest("name:\n  - key: \"one\"\n     other: \"two\"\ninit {}\n")

  test "strict scalars and header operators are rejected":
    expect ManifestParseError:
      discard parseManifest("name: example\ninit {}\n")
    expect ManifestParseError:
      discard parseManifest("name +: \"example\"\ninit {}\n")
    expect ManifestParseError:
      discard parseManifest("count: -1\ninit {}\n")
    expect ManifestParseError:
      discard parseManifest("core-version: \"1.0.0\"\ninit {}\n")

  test "strict function names reject reserved and colliding forms":
    expect ManifestParseError:
      discard parseManifest("name: \"x\"\ninit qualified {}\n")
    expect ManifestParseError:
      discard parseManifest("name: \"x\"\ninit {}\nfunc init_helper {}\n")
    expect ManifestParseError:
      discard parseManifest("name: \"x\"\ninit_helper {}\n")
    expect ManifestParseError:
      discard parseManifest("name: \"x\"\ninit {}\nstart unit {}\nfunc start_unit {}\n")

  test "expression call arguments remain separate":
    let parsed = parseManifest("""
name: "x"
init {
  print '${spawn("/bin/echo", "a, b", "${name}").output()}'
}
""")
    check parsed.manifestCalls.len == 1
    check parsed.manifestCalls[0].name == "spawn"
    check parsed.manifestCalls[0].args == @["/bin/echo", "a, b", "${name}"]

  test "computed expression names are rejected":
    expect ManifestParseError:
      discard parseManifest("name: \"x\"\ninit {\n print \"${${name}(\"x\")}\"\n}\n")

  test "ordinary parsing remains permissive and string typed":
    var p = initParser(tokenize("enabled: true\ncount: 42\ndepends +:\n  - \"a\"\nbuild {}\n"))
    let ordinary = p.parse()
    check ordinary.manifestHeader == nil
    check ordinary.variables[0].varValue == "true"
    check ordinary.variables[1].varValue == "42"
    check ordinary.variables[2].listOp == opAppend

  test "the kongue(5) spawn example with escaped quotes is accepted":
    # Exact example from man/kongue.5.md, MANIFEST MODE.
    let parsed = parseManifest("""name: "x"
init {
    if "${spawn(\"/usr/bin/test\", \"-x\", \"/usr/bin/example\").exit()}" == "0" {
        print "example is installed"
    }
}
""")
    check parsed.manifestCalls.len == 1
    check parsed.manifestCalls[0].name == "spawn"
    check parsed.manifestCalls[0].args == @["/usr/bin/test", "-x", "/usr/bin/example"]
    check parsed.manifestCalls[0].line == 3

  test "the jumpstart-cores spawn status example keeps interpolations per argument":
    let parsed = parseManifest("""name: "x"
init {
}
func service_status {
  if "${spawn(\"/sbin/rc-service\", \"--\", \"${op.unit}\", \"status\").exit()}" == "0" {
    respond state "active"
  }
}
""")
    check parsed.manifestCalls.len == 1
    check parsed.manifestCalls[0].args == @["/sbin/rc-service", "--", "${op.unit}", "status"]

  test "escaped expression arguments must be closed and well formed":
    expect ManifestParseError:
      discard parseManifest("name: \"x\"\ninit {\n  print \"${spawn(\\\"/bin/a)}\"\n}\n")
    expect ManifestParseError:
      discard parseManifest("name: \"x\"\ninit {\n  print \"${spawn(\\\"/bin/a\\\" \\\"b\\\")}\"\n}\n")

  test "header text after the first function block is rejected":
    try:
      discard parseManifest("name: \"x\"\ninit {\n}\naccount: \"late\"\n")
      check false
    except ManifestParseError as e:
      check "must precede the first function block" in e.msg
      check e.line == 4
    try:
      discard parseManifest("name: \"x\"\ninit {\n}\nstray words here\n")
      check false
    except ManifestParseError as e:
      check "outside a function block" in e.msg
      check e.line == 4

  test "tabs are rejected only in header indentation":
    let parsed = parseManifest("name: \"x\"\ninit {\n\tprint \"tabbed\"\n}\n")
    check parsed.functions.len == 1
    try:
      discard parseManifest("modes:\n  - \"system\"\n\t- \"user\"\ninit {}\n")
      check false
    except ManifestParseError as e:
      check e.line == 3

  test "a key without a nested block is an empty value":
    let parsed = parseManifest("""subsystems:
supported_ops:  # nothing yet
items:
  - name: "a"
    options:
    functions:
      - handler: "h"
init {}
""")
    let h = parsed.manifestHeader
    check h.getHeader("subsystems").emptyBlock
    check h.getHeader("subsystems").listVal.len == 0
    check h.getHeader("supported_ops").emptyBlock
    let item = h.getHeader("items").listVal[0]
    check item.getHeader("options").emptyBlock
    check item.getHeader("functions").listVal[0].getHeader("handler").stringVal == "h"

  test "underscore keys are single keys and qualifiers are not keys":
    let parsed = parseManifest("core_version: \"1.0.0\"\ninit {}\n")
    check parsed.manifestHeader.mapVal[0].key == "core_version"
    expect ManifestParseError:
      discard parseManifest("core version: \"1.0.0\"\ninit {}\n")

  test "body variable references are exact":
    let parsed = parseManifest("""name: "x"
init {
  print "${op.unit}|${Op.unit}|${OP.unit}"
}
""")
    let ctx = initExecutionContext()
    ctx.silent = true
    ctx.loadAllFunctions(parsed)
    var values = initTable[string, VarValue]()
    values["unit"] = newStringValue("sshd")
    ctx.setObjectVariable("op", newObjectValue(values))
    check ctx.resolveVariables("${op.unit}|${Op.unit}|${OP.unit}") == "sshd||"
    ctx.setVariable("core_version", "1.0.0")
    check ctx.resolveVariables("$core_version/$coreVersion/${core-version}") == "1.0.0//"
    check ctx.evaluateCondition("\"${op.unit}\" == \"sshd\"")
    check not ctx.evaluateCondition("\"${Op.unit}\" == \"sshd\"")

  test "bare KEY=VALUE arguments keep their exact text (jumpstart-cores §16.3)":
    let parsed = parseManifest("name: \"x\"\nfunc list {\n" &
      "  respond-item units name=a-b.service subsystem=\"svc\" enablement=${op.args.e}\n" &
      "  respond-item units \"name=quoted value\" subsystem=s enablement=\n}\n")
    let body = parsed.customFuncs[0].customFuncBody
    check body[0].callName == "respond-item"
    check body[0].callArgs == @["units name=a-b.service", "subsystem=\"svc\"",
                                "enablement=${op.args.e}"]
    check body[1].callArgs == @["units \"name=quoted value\" subsystem=s", "enablement="]
