## Test program for run3 module
## Uses unittest module for structured testing

import unittest
import os
import times
import strutils

import ../../kpkg/modules/run3/run3
import ../../kongue/utils

suite "run3 lexer":
  test "tokenizes basic input":
    let testInput = "name: \"test\"\n" &
                    "version: \"1.0\"\n" &
                    "build {\n" &
                    "    print \"Hello\"\n" &
                    "    write \"file.txt\" \"\"\"\n" &
                    "Multi-line\n" &
                    "String\n" &
                    "\"\"\"\n" &
                    "}\n"

    let tokens = tokenize(testInput)
    check tokens.len > 0
    # Verify first few tokens exist
    check tokens.len >= 10

suite "run3 parser":
  var testDir: string

  setup:
    testDir = "/tmp/test-run3-parser-" & $getTime().toUnix()
    createDir(testDir)

  teardown:
    removeDir(testDir)

  test "parses run3 file correctly":
    let testContent = """
name: "test-pkg"
version: "1.0.0"
release: "1"
description: "Test package"
sources:
        - "https://example.com/test.tar.gz"
depends:
        - "dep1"
        - "dep2"
sha256sum:
        - "abc123"

func helper {
        print "Helper function called"
}

build {
        print "Building package"
        exec "echo Test build"
        cd /tmp
}

package {
        print "Installing package"
}
"""
    writeFile(testDir / "run3", testContent)

    let rf = parseRun3(testDir)

    check rf.getName() == "test-pkg"
    check rf.getVersion() == "1.0.0"
    check rf.getRelease() == "1"
    check rf.getDescription() == "Test package"
    check rf.getSources().len == 1
    check rf.getSources()[0] == "https://example.com/test.tar.gz"
    check rf.getDepends().len == 2
    check "dep1" in rf.getDepends()
    check "dep2" in rf.getDepends()
    check rf.getVersionString() == "1.0.0-1"
    check rf.getAllFunctions().len > 0
    check "helper" in rf.getAllCustomFunctions()

suite "run3 variables":
  test "split method":
    let strVal = newStringValue("1.2.3")
    let splitResult = applyMethod(strVal, "split", @["."])
    check splitResult.toList() == @["1", "2", "3"]

  test "join method":
    let listVal = newListValue(@["a", "b", "c"])
    let joinResult = applyMethod(listVal, "join", @["-"])
    check joinResult.toString() == "a-b-c"

  test "cut method":
    let strVal = newStringValue("1.2.3")
    let cutResult = applyMethod(strVal, "cut", @["0", "3"])
    check cutResult.toString() == "1.2"

  test "replace method":
    let strVal = newStringValue("1.2.3")
    let replaceResult = applyMethod(strVal, "replace", @[".", "_"])
    check replaceResult.toString() == "1_2_3"

  test "indexing":
    let strVal = newStringValue("1.2.3")
    let splitResult = applyMethod(strVal, "split", @["."])
    let indexResult = applyIndex(splitResult, "0")
    check indexResult.toString() == "1"

  test "slicing":
    let strVal = newStringValue("1.2.3")
    let splitResult = applyMethod(strVal, "split", @["."])
    let sliceResult = applyIndex(splitResult, "0:2")
    check sliceResult.toList() == @["1", "2"]

suite "run3 builtins":
  test "variable set/get":
    let ctx = initRun3Context()
    ctx.silent = true
    ctx.passthrough = true

    ctx.setVariable("test_var", "hello")
    check ctx.getVariable("test_var") == "hello"

  test "list variable":
    let ctx = initRun3Context()
    ctx.silent = true

    ctx.setListVariable("test_list", @["a", "b", "c"])
    check ctx.getListVariable("test_list") == @["a", "b", "c"]

  test "variable resolution":
    let ctx = initRun3Context()
    ctx.silent = true

    ctx.setVariable("name", "world")
    let resolved = ctx.resolveVariables("Hello $name and ${name}!")
    check resolved == "Hello world and world!"

  test "cd builtin":
    let ctx = initRun3Context()
    ctx.silent = true
    ctx.passthrough = true

    let originalDir = getCurrentDir()
    discard ctx.builtinCd("/tmp")
    check ctx.currentDir == "/tmp"
    setCurrentDir(originalDir)

  test "write builtin":
    let ctx = initRun3Context()
    ctx.silent = true
    ctx.passthrough = true

    let testFile = "test_write_unittest.txt"
    let writeContent = "Line 1"

    ctx.builtinWrite(testFile, writeContent)
    check readFile(ctx.currentDir / testFile) == writeContent

    removeFile(ctx.currentDir / testFile)

  test "append builtin":
    let ctx = initRun3Context()
    ctx.silent = true
    ctx.passthrough = true

    let testFile = "test_append_unittest.txt"
    let writeContent = "Line 1"
    let appendContent = "\nLine 2"

    ctx.builtinWrite(testFile, writeContent)
    ctx.builtinAppend(testFile, appendContent)
    check readFile(ctx.currentDir / testFile) == writeContent & appendContent

    removeFile(ctx.currentDir / testFile)

suite "run3 macros":
  test "macro argument parsing - internal args only":
    let ctx = initRun3Context()
    ctx.silent = true

    let args = parseMacroArgs(@["--meson", "--autocd=true",
        "--prefix=/usr/local"])
    check args.buildSystem == bsMeson
    check args.autocd == true
    check args.prefix == "/usr/local"
    check args.passthroughArgs == ""

  test "macro argument parsing - mixed args":
    let args = parseMacroArgs(@["--ninja", "-Dplatforms=wayland,x11",
        "-Dgallium-drivers=auto", "--enable-foo", "install.prefix=/usr"])

    check args.buildSystem == bsNinja
    check "-Dplatforms=wayland,x11" in args.passthroughArgs
    check "-Dgallium-drivers=auto" in args.passthroughArgs
    check "--enable-foo" in args.passthroughArgs
    check "install.prefix=/usr" in args.passthroughArgs
    check "--ninja" notin args.passthroughArgs

  test "macro argument parsing - set style args":
    let args = parseMacroArgs(@["--set", "install.prefix=/usr", "--set",
        "llvm.link-shared=true", "--llvm-config=/usr/bin/llvm-config"])

    check "--set" in args.passthroughArgs
    check "install.prefix=/usr" in args.passthroughArgs
    check "--llvm-config=/usr/bin/llvm-config" in args.passthroughArgs

suite "run3 variable operations":
  var testDir: string

  setup:
    testDir = "/tmp/test-run3-ops-" & $getTime().toUnix()
    createDir(testDir)

  teardown:
    removeDir(testDir)

  test "list append and remove operators":
    let testContent = """
name: "test-pkg"
depends:
    - "dep1"
    - "dep2"

depends+:
    - "dep3"

depends-:
    - "dep1"

cflags: "-O2"
cflags+: "-g"
"""
    writeFile(testDir / "run3", testContent)

    let rf = parseRun3(testDir)
    let ctx = initRun3ContextFromParsed(rf.parsed)

    let depends = ctx.getListVariable("depends")
    check "dep3" in depends
    check "dep1" notin depends

    let cflags = ctx.getVariable("cflags")
    check cflags == "-O2 -g"

suite "run3 exec manipulation":
  test "exec output":
    let ctx = initRun3Context()
    ctx.silent = true
    ctx.passthrough = true

    let output = ctx.resolveVariables("Hello ${exec(\"echo world\").output()}!")
    check output == "Hello world!"

  test "exec exit code":
    let ctx = initRun3Context()
    ctx.silent = true
    ctx.passthrough = true

    let exitCode = ctx.resolveVariables("Exit code: ${exec(\"true\").exit()}")
    check exitCode == "Exit code: 0"

  test "exec chaining with strip":
    let ctx = initRun3Context()
    ctx.silent = true
    ctx.passthrough = true

    let output = ctx.resolveVariables("${exec(\"echo ' test '\").strip()}")
    check output == "test"

suite "run3 conditions":
  test "basic boolean true":
    let ctx = initRun3Context()
    ctx.silent = true

    ctx.setVariable("enabled", "true")
    check ctx.evaluateCondition("$enabled")

  test "basic boolean false":
    let ctx = initRun3Context()
    ctx.silent = true

    ctx.setVariable("disabled", "false")
    check not ctx.evaluateCondition("$disabled")

  test "equality check":
    let ctx = initRun3Context()
    ctx.silent = true

    ctx.setVariable("version", "1.0.0")
    check ctx.evaluateCondition("$version == \"1.0.0\"")

  test "inequality check":
    let ctx = initRun3Context()
    ctx.silent = true

    ctx.setVariable("name", "pkg")
    check ctx.evaluateCondition("$name != \"other\"")

suite "run3 condition operators":
  test "OR operator - first true":
    let ctx = initRun3Context()
    ctx.silent = true
    ctx.passthrough = true

    ctx.setVariable("name", "grep")
    check ctx.evaluateCondition("\"$name\" == \"grep\" || \"$name\" == \"tar\"")

  test "OR operator - second true":
    let ctx = initRun3Context()
    ctx.silent = true
    ctx.passthrough = true

    ctx.setVariable("name", "tar")
    check ctx.evaluateCondition("\"$name\" == \"grep\" || \"$name\" == \"tar\"")

  test "OR operator - both false":
    let ctx = initRun3Context()
    ctx.silent = true
    ctx.passthrough = true

    ctx.setVariable("name", "other")
    check not ctx.evaluateCondition("\"$name\" == \"grep\" || \"$name\" == \"tar\"")

  test "AND operator - both true":
    let ctx = initRun3Context()
    ctx.silent = true
    ctx.passthrough = true

    ctx.setVariable("debug", "true")
    ctx.setVariable("verbose", "true")
    check ctx.evaluateCondition("\"$debug\" == \"true\" && \"$verbose\" == \"true\"")

  test "AND operator - one false":
    let ctx = initRun3Context()
    ctx.silent = true
    ctx.passthrough = true

    ctx.setVariable("debug", "true")
    ctx.setVariable("verbose", "false")
    check not ctx.evaluateCondition("\"$debug\" == \"true\" && \"$verbose\" == \"true\"")

  test "regex match operator - matches":
    let ctx = initRun3Context()
    ctx.silent = true
    ctx.passthrough = true

    ctx.setVariable("name", "grep")
    check ctx.evaluateCondition("\"$name\" =~ e\"grep|tar|bzip2\"")

    ctx.setVariable("name", "tar")
    check ctx.evaluateCondition("\"$name\" =~ e\"grep|tar|bzip2\"")

  test "regex match operator - no match":
    let ctx = initRun3Context()
    ctx.silent = true
    ctx.passthrough = true

    ctx.setVariable("name", "other")
    check not ctx.evaluateCondition("\"$name\" =~ e\"grep|tar|bzip2\"")

suite "run3 control flow":
  var testDir: string

  setup:
    testDir = "/tmp/test-run3-control-" & $getTime().toUnix()
    createDir(testDir)

  teardown:
    removeDir(testDir)

  test "continue and break":
    let testContent = """
name: "test-pkg"
version: "1.0.0"
release: "1"
description: "Test"
items:
    - "a"
    - "SKIP"
    - "b"
    - "STOP"
    - "c"
    - "d"
result: ""
count: "0"

package {
    for item in items {
        if "$item" == "SKIP" {
            continue
        }
        if "$item" == "STOP" {
            break
        }
        global result = "$result$item "
        print "Processing: $item"
    }
    print "Result: $result"
}
"""
    writeFile(testDir / "run3", testContent)

    let rf = parseRun3(testDir)
    let ctx = initRun3ContextFromParsed(rf.parsed)
    ctx.silent = false
    ctx.passthrough = true

    discard ctx.executeFunctionByName(rf.parsed, "package")

    let result = ctx.getVariable("result").strip()
    check result == "a b"

suite "run3 utils helpers":
  test "stripQuotes":
    check stripQuotes("\"hello\"") == "hello"
    check stripQuotes("'world'") == "world"
    check stripQuotes("noquotes") == "noquotes"
    check stripQuotes("\"\"") == ""
    check stripQuotes("''") == ""
    check stripQuotes("\"only start") == "\"only start"
    check stripQuotes("only end\"") == "only end\""

  test "extractBraceExpr":
    let (expr1, end1) = extractBraceExpr("${foo}", 0)
    check expr1 == "foo"
    check end1 == 6

    let (expr2, end2) = extractBraceExpr("prefix${bar}suffix", 6)
    check expr2 == "bar"
    check end2 == 12

    let (expr3, end3) = extractBraceExpr("${nested.method()}", 0)
    check expr3 == "nested.method()"
    check end3 == 18

    let (expr4, end4) = extractBraceExpr("nope", 0)
    check expr4 == ""
    check end4 == 0

  test "parseConditionOperator":
    let cp1 = parseConditionOperator("left == right")
    check cp1.valid
    check cp1.left == "left"
    check cp1.op == "=="
    check cp1.right == "right"

    let cp2 = parseConditionOperator("foo != bar")
    check cp2.valid
    check cp2.left == "foo"
    check cp2.op == "!="
    check cp2.right == "bar"

    let cp3 = parseConditionOperator("value =~ e\"pattern\"")
    check cp3.valid
    check cp3.left == "value"
    check cp3.op == "=~"
    check cp3.right == "e\"pattern\""

    let cp4 = parseConditionOperator("no operator here")
    check not cp4.valid

  test "stripPatternWrapper":
    check stripPatternWrapper("e\"pattern\"") == "pattern"
    check stripPatternWrapper("e'pattern'") == "pattern"
    check stripPatternWrapper("\"quoted\"") == "quoted"
    check stripPatternWrapper("'single'") == "single"
    check stripPatternWrapper("plain") == "plain"

  test "isTrueBoolean and isFalseBoolean":
    check isTrueBoolean("true")
    check isTrueBoolean("TRUE")
    check isTrueBoolean("1")
    check isTrueBoolean("yes")
    check isTrueBoolean("on")
    check not isTrueBoolean("false")
    check not isTrueBoolean("maybe")

    check isFalseBoolean("false")
    check isFalseBoolean("FALSE")
    check isFalseBoolean("0")
    check isFalseBoolean("no")
    check isFalseBoolean("off")
    check isFalseBoolean("")
    check not isFalseBoolean("true")
    check not isFalseBoolean("maybe")

  test "splitLogicalOr and splitLogicalAnd":
    let orParts = splitLogicalOr("a || b || c")
    check orParts == @["a", "b", "c"]

    let andParts = splitLogicalAnd("x && y && z")
    check andParts == @["x", "y", "z"]

    let single = splitLogicalOr("single")
    check single == @["single"]

  test "isSimpleVarName":
    check isSimpleVarName("foo")
    check isSimpleVarName("_bar")
    check isSimpleVarName("test123")
    check isSimpleVarName("my-var")
    check isSimpleVarName("my_var")
    check not isSimpleVarName("")
    check not isSimpleVarName("123abc")
    check not isSimpleVarName("has.dot")
    check not isSimpleVarName("has space")
    check not isSimpleVarName("has(paren)")

  test "findMatchingBrace":
    check findMatchingBrace("${foo}", 1) == 5
    check findMatchingBrace("${a{b}c}", 1) == 7
    check findMatchingBrace("${unclosed", 1) == -1

suite "run3 for loop":
  test "for loop with variable expression":
    let ctx = initRun3Context()
    ctx.silent = true
    ctx.passthrough = true

    ctx.setVariable("items", "apple\nbanana\ncherry")

    var collected: seq[string] = @[]
    let itemsStr = ctx.getVariable("items")
    let items = itemsStr.splitLines()

    for item in items:
      if item.strip().len > 0:
        collected.add(item)

    check collected == @["apple", "banana", "cherry"]
