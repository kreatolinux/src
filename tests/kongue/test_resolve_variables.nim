## Tests for kongue resolveVariables, focused on object variable handling.
## Standalone (imports only kongue modules) so it runs without the full kpkg
## build-chain (e.g. libarchive) available.

import unittest
import tables

import ../../kongue/context
import ../../kongue/variables
import ../../kongue/builtins
import ../../kongue/lexer
import ../../kongue/parser
import ../../kongue/executor
import ../../kongue/utils

proc newCtx(): ExecutionContext =
  result = initExecutionContext()
  result.silent = true

proc kpkgObject(isBootstrap: string): VarValue =
  var props = initTable[string, VarValue]()
  props["isBootstrap"] = newStringValue(isBootstrap)
  result = newObjectValue(props)

suite "resolveVariables - object property access":

  test "bracket access object key resolves":
    let ctx = newCtx()
    ctx.setObjectVariable("kpkg", kpkgObject("0"))
    check ctx.resolveVariables("kpkg[\"isBootstrap\"]") == "0"

  test "explicit dot access via braces resolves":
    let ctx = newCtx()
    ctx.setObjectVariable("kpkg", kpkgObject("1"))
    check ctx.resolveVariables("${kpkg.isBootstrap}") == "1"

  test "bare dotted filename is not mangled (regression)":
    # A `kpkg` object variable is auto-injected for every build, so any
    # filename of the form `kpkg.<ext>` (e.g. kpkg.nim) was previously
    # misread as bare property access `kpkg.<ext>` and deleted, turning
    # "kpkg/kpkg.nim" into "kpkg/". Bare dot access is now resolved only via
    # the explicit ${object.key} syntax (per man/kongue.5.md).
    let ctx = newCtx()
    ctx.setObjectVariable("kpkg", kpkgObject("0"))
    check ctx.resolveVariables("\"kpkg/kpkg.nim\"") == "\"kpkg/kpkg.nim\""
    check ctx.resolveVariables("nim c -o=\"out/kpkg\" \"kpkg/kpkg.nim\"") ==
      "nim c -o=\"out/kpkg\" \"kpkg/kpkg.nim\""

  test "bare dot access to non-existent property leaves text intact":
    # kpkg has no `nim` property; previously this deleted `kpkg.nim`.
    let ctx = newCtx()
    ctx.setObjectVariable("kpkg", kpkgObject("0"))
    check ctx.resolveVariables("kpkg.nim") == "kpkg.nim"

  test "non-object identifier with dot is untouched":
    # `jumpstart` is not a registered object variable, so jumpstart.nim must
    # pass through unchanged regardless.
    let ctx = newCtx()
    ctx.setObjectVariable("kpkg", kpkgObject("0"))
    check ctx.resolveVariables("\"jumpstart/jumpstart.nim\"") ==
      "\"jumpstart/jumpstart.nim\""

  test "object property embedded in a larger command":
    let ctx = newCtx()
    ctx.setObjectVariable("kpkg", kpkgObject("1"))
    check ctx.resolveVariables("echo ${kpkg.isBootstrap} && build kpkg.nim") ==
      "echo 1 && build kpkg.nim"

  test "unquoted env path values are not spaced apart":
    let content = """
build {
  env DEPMOD=/nodepmod/here
}
"""
    let tokens = tokenize(content)
    var parser = initParser(tokens)
    let parsed = parser.parse()
    let ctx = newCtx()

    check ctx.executeFunctionByName(parsed, "build") == 0
    check ctx.envVars["DEPMOD"] == "/nodepmod/here"
