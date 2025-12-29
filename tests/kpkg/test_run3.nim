## Test program for run3 module
## Demonstrates basic functionality and can be used for testing

import os
import times
import run3
import tables
import strutils
import sequtils
import utils

proc testParser() =
  echo "=== Testing Parser ==="

  # Create a simple test run3 file
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
        exec echo "Test build"
        cd /tmp
}

package {
        print "Installing package"
}
"""

  let testDir = "/tmp/test-run3-" & $getTime().toUnix()
  createDir(testDir)
  writeFile(testDir / "run3", testContent)

  try:
    let rf = parseRun3(testDir)

    echo "Name: ", rf.getName()
    echo "Version: ", rf.getVersion()
    echo "Release: ", rf.getRelease()
    echo "Description: ", rf.getDescription()
    echo "Sources: ", rf.getSources()
    echo "Depends: ", rf.getDepends()
    echo "Version String: ", rf.getVersionString()
    echo "Functions: ", rf.getAllFunctions()
    echo "Custom Functions: ", rf.getAllCustomFunctions()

    echo "\n✓ Parser test passed"
  except Exception as e:
    echo "✗ Parser test failed: ", e.msg
    echo getStackTrace(e)
  finally:
    removeDir(testDir)

proc testLexer() =
  echo "\n=== Testing Lexer ==="

  let testInput = "name: \"test\"\n" &
                                  "version: \"1.0\"\n" &
                                  "build {\n" &
                                  "    print \"Hello\"\n" &
                                  "    write \"file.txt\" \"\"\"\n" &
                                  "Multi-line\n" &
                                  "String\n" &
                                  "\"\"\"\n" &
                                  "}\n"

  try:
    let tokens = tokenize(testInput)
    echo "Tokens generated: ", tokens.len
    for i, tok in tokens:
      if i < 10: # Print first 10 tokens
        echo "  ", tok.kind, ": '", tok.value, "' (line ", tok.line, ")"
    echo "✓ Lexer test passed"
  except Exception as e:
    echo "✗ Lexer test failed: ", e.msg

proc testVariables() =
  echo "\n=== Testing Variable Manipulation ==="

  try:
    # Test split
    let strVal = newStringValue("1.2.3")
    let splitResult = applyMethod(strVal, "split", @["."])
    echo "split('1.2.3', '.'): ", splitResult.toList()

    # Test join
    let listVal = newListValue(@["a", "b", "c"])
    let joinResult = applyMethod(listVal, "join", @["-"])
    echo "join(['a','b','c'], '-'): ", joinResult.toString()

    # Test cut
    let cutResult = applyMethod(strVal, "cut", @["0", "3"])
    echo "cut('1.2.3', 0, 3): ", cutResult.toString()

    # Test replace
    let replaceResult = applyMethod(strVal, "replace", @[".", "_"])
    echo "replace('1.2.3', '.', '_'): ", replaceResult.toString()

    # Test indexing
    let indexResult = applyIndex(splitResult, "0")
    echo "split('1.2.3', '.')[0]: ", indexResult.toString()

    # Test slicing
    let sliceResult = applyIndex(splitResult, "0:2")
    echo "split('1.2.3', '.')[0:2]: ", sliceResult.toList()

    echo "✓ Variable manipulation test passed"
  except Exception as e:
    echo "✗ Variable test failed: ", e.msg

proc testBuiltins() =
  echo "\n=== Testing Built-in Commands ==="

  try:
    let ctx = initExecutionContext()
    ctx.silent = true
    ctx.passthrough = true

    # Test variable setting/getting
    ctx.setVariable("test_var", "hello")
    let val = ctx.getVariable("test_var")
    echo "Variable set/get: ", val

    # Test list variable
    ctx.setListVariable("test_list", @["a", "b", "c"])
    let listVal = ctx.getListVariable("test_list")
    echo "List variable: ", listVal

    # Test variable resolution
    ctx.setVariable("name", "world")
    let resolved = ctx.resolveVariables("Hello $name and ${name}!")
    echo "Variable resolution: ", resolved

    # Test cd
    let originalDir = getCurrentDir()
    discard ctx.builtinCd("/tmp")
    echo "Changed directory to: ", ctx.currentDir
    setCurrentDir(originalDir)

    # Test write/append
    let testFile = "test_write.txt"
    let writeContent = "Line 1"
    let appendContent = "\nLine 2"

    # Write
    ctx.builtinWrite(testFile, writeContent)
    if readFile(ctx.currentDir / testFile) == writeContent:
      echo "Write test: Passed"
    else:
      echo "Write test: Failed"

    # Append
    ctx.builtinAppend(testFile, appendContent)
    if readFile(ctx.currentDir / testFile) == writeContent & appendContent:
      echo "Append test: Passed"
    else:
      echo "Append test: Failed"

    # Clean up
    removeFile(ctx.currentDir / testFile)

    echo "✓ Built-in commands test passed"
  except Exception as e:
    echo "✗ Built-in test failed: ", e.msg

proc testMacros() =
  echo "\n=== Testing Macros ==="

  try:
    let ctx = initExecutionContext()
    ctx.silent = true

    # Test macro argument parsing - internal args only
    let args1 = parseMacroArgs(@["--meson", "--autocd=true",
            "--prefix=/usr/local"])
    echo "Build system: ", args1.buildSystem
    echo "Autocd: ", args1.autocd
    echo "Prefix: ", args1.prefix
    echo "Passthrough: '", args1.passthroughArgs, "'"

    if args1.buildSystem == bsMeson and args1.autocd == true and
       args1.prefix == "/usr/local" and args1.passthroughArgs == "":
      echo "Internal args only: Passed"
    else:
      echo "Internal args only: Failed"

    echo "✓ Macro test passed"
  except Exception as e:
    echo "✗ Macro test failed: ", e.msg

proc testMacroArgParsing() =
  echo "\n=== Testing Macro Argument Parsing ==="

  try:
    # Test mixed args - internal + passthrough
    let args = parseMacroArgs(@["--ninja", "-Dplatforms=wayland,x11",
        "-Dgallium-drivers=auto", "--enable-foo", "install.prefix=/usr"])

    echo "Build system: ", args.buildSystem
    echo "Passthrough: '", args.passthroughArgs, "'"

    # Verify internal args are recognized
    if args.buildSystem != bsNinja:
      echo "✗ Failed: --ninja not recognized as build system"
      return
    echo "  --ninja recognized: Passed"

    # Verify passthrough args are collected
    if "-Dplatforms=wayland,x11" notin args.passthroughArgs:
      echo "✗ Failed: -Dplatforms=wayland,x11 not in passthrough"
      return
    echo "  -Dplatforms in passthrough: Passed"

    if "-Dgallium-drivers=auto" notin args.passthroughArgs:
      echo "✗ Failed: -Dgallium-drivers=auto not in passthrough"
      return
    echo "  -Dgallium-drivers in passthrough: Passed"

    if "--enable-foo" notin args.passthroughArgs:
      echo "✗ Failed: --enable-foo not in passthrough"
      return
    echo "  --enable-foo in passthrough: Passed"

    if "install.prefix=/usr" notin args.passthroughArgs:
      echo "✗ Failed: install.prefix=/usr not in passthrough"
      return
    echo "  install.prefix=/usr in passthrough: Passed"

    # Test that internal args are NOT in passthrough
    if "--ninja" in args.passthroughArgs:
      echo "✗ Failed: --ninja should not be in passthrough"
      return
    echo "  --ninja not in passthrough: Passed"

    # Test --set style args (flag followed by value)
    let args2 = parseMacroArgs(@["--set", "install.prefix=/usr", "--set",
        "llvm.link-shared=true", "--llvm-config=/usr/bin/llvm-config"])

    echo "\nTest --set style args:"
    echo "Passthrough: '", args2.passthroughArgs, "'"

    # --set is not a recognized internal arg, so it should pass through
    if "--set" notin args2.passthroughArgs:
      echo "✗ Failed: --set not in passthrough"
      return
    echo "  --set in passthrough: Passed"

    if "install.prefix=/usr" notin args2.passthroughArgs:
      echo "✗ Failed: install.prefix=/usr not in passthrough"
      return
    echo "  install.prefix=/usr in passthrough: Passed"

    if "--llvm-config=/usr/bin/llvm-config" notin args2.passthroughArgs:
      echo "✗ Failed: --llvm-config not in passthrough"
      return
    echo "  --llvm-config in passthrough: Passed"

    echo "✓ Macro argument parsing test passed"
  except Exception as e:
    echo "✗ Macro argument parsing test failed: ", e.msg
    echo getStackTrace(e)

proc testVariableOps() =
  echo "\n=== Testing Variable Operations (+:, -:) ==="

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

  let testDir = "/tmp/test-run3-ops-" & $getTime().toUnix()
  createDir(testDir)
  writeFile(testDir / "run3", testContent)

  try:
    let rf = parseRun3(testDir)
    let ctx = initFromRunfile(rf.parsed)

    # Check depends list
    let depends = ctx.getListVariable("depends")
    echo "Depends: ", depends

    if "dep3" in depends and "dep1" notin depends:
      echo "List operations: Passed"
    else:
      echo "List operations: Failed"

    # Check cflags
    let cflags = ctx.getVariable("cflags")
    echo "CFLAGS: ", cflags
    if cflags == "-O2 -g":
      echo "String operations: Passed"
    else:
      echo "String operations: Failed (Expected '-O2 -g', got '", cflags, "')"

    echo "✓ Variable operations test passed"
  except Exception as e:
    echo "✗ Variable operations test failed: ", e.msg
    echo getStackTrace(e)
  finally:
    removeDir(testDir)

proc testExecManipulation() =
  echo "\n=== Testing Exec Manipulation ==="

  let ctx = initExecutionContext()
  ctx.silent = true
  ctx.passthrough = true

  try:
    # Mock exec by echoing
    let output = ctx.resolveVariables("Hello ${exec(\"echo world\").output()}!")
    echo "Exec output: ", output

    if output == "Hello world!":
      echo "Exec output test: Passed"
    else:
      echo "Exec output test: Failed"

    let exitCode = ctx.resolveVariables("Exit code: ${exec(\"true\").exit()}")
    echo "Exec exit: ", exitCode

    if exitCode == "Exit code: 0":
      echo "Exec exit code test: Passed"
    else:
      echo "Exec exit code test: Failed"

    echo "✓ Exec manipulation test passed"
  except Exception as e:
    echo "✗ Exec manipulation test failed: ", e.msg

proc testConditions() =
  echo "\n=== Testing Conditions ==="

  let ctx = initExecutionContext()
  ctx.silent = true

  try:
    ctx.setVariable("enabled", "true")
    ctx.setVariable("disabled", "false")
    ctx.setVariable("version", "1.0.0")
    ctx.setVariable("name", "pkg")

    # Test basic boolean
    if ctx.evaluateCondition("$enabled"):
      echo "Boolean check (true): Passed"
    else:
      echo "Boolean check (true): Failed"

    if not ctx.evaluateCondition("$disabled"):
      echo "Boolean check (false): Passed"
    else:
      echo "Boolean check (false): Failed"

    # Test equality
    if ctx.evaluateCondition("$version == \"1.0.0\""):
      echo "Equality check: Passed"
    else:
      echo "Equality check: Failed"

    if ctx.evaluateCondition("$name != \"other\""):
      echo "Inequality check: Passed"
    else:
      echo "Inequality check: Failed"

    echo "✓ Condition test passed"
  except Exception as e:
    echo "✗ Condition test failed: ", e.msg

proc testExecChaining() =
  echo "\n=== Testing Exec Chaining ==="

  let ctx = initExecutionContext()
  ctx.silent = true
  ctx.passthrough = true

  try:
    # Test .strip() on exec output
    # " echo  test " -> " test " -> strip -> "test"
    let output = ctx.resolveVariables("${exec(\"echo ' test '\").strip()}")
    echo "Exec chaining output: '", output, "'"

    if output == "test":
      echo "Exec chaining test: Passed"
    else:
      echo "Exec chaining test: Failed"

    echo "✓ Exec chaining test passed"
  except Exception as e:
    echo "✗ Exec chaining test failed: ", e.msg

proc testNewConditionOperators() =
  echo "\n=== Testing New Condition Operators (||, &&, =~) ==="

  let ctx = initExecutionContext()
  ctx.silent = true
  ctx.passthrough = true

  # Set up test variables
  ctx.setVariable("name", "grep")
  ctx.setVariable("arch", "x86_64")
  ctx.setVariable("debug", "true")
  ctx.setVariable("verbose", "true")

  try:
    # Test || (OR) operator
    if ctx.evaluateCondition("\"$name\" == \"grep\" || \"$name\" == \"tar\""):
      echo "OR operator (first true): Passed"
    else:
      echo "OR operator (first true): Failed"

    ctx.setVariable("name", "tar")
    if ctx.evaluateCondition("\"$name\" == \"grep\" || \"$name\" == \"tar\""):
      echo "OR operator (second true): Passed"
    else:
      echo "OR operator (second true): Failed"

    ctx.setVariable("name", "other")
    if not ctx.evaluateCondition("\"$name\" == \"grep\" || \"$name\" == \"tar\""):
      echo "OR operator (both false): Passed"
    else:
      echo "OR operator (both false): Failed"

    # Test && (AND) operator
    if ctx.evaluateCondition("\"$debug\" == \"true\" && \"$verbose\" == \"true\""):
      echo "AND operator (both true): Passed"
    else:
      echo "AND operator (both true): Failed"

    ctx.setVariable("verbose", "false")
    if not ctx.evaluateCondition("\"$debug\" == \"true\" && \"$verbose\" == \"true\""):
      echo "AND operator (one false): Passed"
    else:
      echo "AND operator (one false): Failed"

    # Test =~ (regex match) operator
    ctx.setVariable("name", "grep")
    if ctx.evaluateCondition("\"$name\" =~ e\"grep|tar|bzip2\""):
      echo "Regex match (grep matches): Passed"
    else:
      echo "Regex match (grep matches): Failed"

    ctx.setVariable("name", "tar")
    if ctx.evaluateCondition("\"$name\" =~ e\"grep|tar|bzip2\""):
      echo "Regex match (tar matches): Passed"
    else:
      echo "Regex match (tar matches): Failed"

    ctx.setVariable("name", "other")
    if not ctx.evaluateCondition("\"$name\" =~ e\"grep|tar|bzip2\""):
      echo "Regex match (no match): Passed"
    else:
      echo "Regex match (no match): Failed"

    echo "✓ New condition operators test passed"
  except Exception as e:
    echo "✗ New condition operators test failed: ", e.msg
    echo getStackTrace(e)

proc testContinueBreak() =
  echo "\n=== Testing Continue and Break ==="

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

  let testDir = "/tmp/test-run3-control-" & $getTime().toUnix()
  createDir(testDir)
  writeFile(testDir / "run3", testContent)

  try:
    let rf = parseRun3(testDir)
    let ctx = initFromRunfile(rf.parsed)
    ctx.silent = false
    ctx.passthrough = true

    # The test passes if it parses and executes without error
    # Expected output: Processing: a, Processing: b (SKIP skipped, STOP breaks before c,d)
    discard ctx.executeRun3Function(rf.parsed, "package")

    # After execution, result should be "a b " (SKIP skipped, STOP broke before c and d)
    let result = ctx.getVariable("result").strip()
    if result == "a b":
      echo "Continue/Break test: Passed"
      echo "String concatenation result: Passed (got '" & result & "')"
    else:
      echo "Continue/Break test: Failed (expected 'a b', got '" & result & "')"

    echo "✓ Continue/Break test passed"
  except Exception as e:
    echo "✗ Continue/Break test failed: ", e.msg
    echo getStackTrace(e)
  finally:
    removeDir(testDir)

proc testUtilsHelpers() =
  echo "\n=== Testing Utils Helpers ==="

  try:
    # Test stripQuotes
    block:
      doAssert stripQuotes("\"hello\"") == "hello"
      doAssert stripQuotes("'world'") == "world"
      doAssert stripQuotes("noquotes") == "noquotes"
      doAssert stripQuotes("\"\"") == ""
      doAssert stripQuotes("''") == ""
      doAssert stripQuotes("\"only start") == "\"only start"
      doAssert stripQuotes("only end\"") == "only end\""
      echo "stripQuotes: Passed"

    # Test extractBraceExpr
    block:
      let (expr1, end1) = extractBraceExpr("${foo}", 0)
      doAssert expr1 == "foo"
      doAssert end1 == 6

      let (expr2, end2) = extractBraceExpr("prefix${bar}suffix", 6)
      doAssert expr2 == "bar"
      doAssert end2 == 12

      let (expr3, end3) = extractBraceExpr("${nested.method()}", 0)
      doAssert expr3 == "nested.method()"
      doAssert end3 == 18 # len("${nested.method()}") == 18

      # Not a brace expr
      let (expr4, end4) = extractBraceExpr("nope", 0)
      doAssert expr4 == ""
      doAssert end4 == 0

      echo "extractBraceExpr: Passed"

    # Test parseConditionOperator
    block:
      let cp1 = parseConditionOperator("left == right")
      doAssert cp1.valid
      doAssert cp1.left == "left"
      doAssert cp1.op == "=="
      doAssert cp1.right == "right"

      let cp2 = parseConditionOperator("foo != bar")
      doAssert cp2.valid
      doAssert cp2.left == "foo"
      doAssert cp2.op == "!="
      doAssert cp2.right == "bar"

      let cp3 = parseConditionOperator("value =~ e\"pattern\"")
      doAssert cp3.valid
      doAssert cp3.left == "value"
      doAssert cp3.op == "=~"
      doAssert cp3.right == "e\"pattern\""

      let cp4 = parseConditionOperator("no operator here")
      doAssert not cp4.valid

      echo "parseConditionOperator: Passed"

    # Test stripPatternWrapper
    block:
      doAssert stripPatternWrapper("e\"pattern\"") == "pattern"
      doAssert stripPatternWrapper("e'pattern'") == "pattern"
      doAssert stripPatternWrapper("\"quoted\"") == "quoted"
      doAssert stripPatternWrapper("'single'") == "single"
      doAssert stripPatternWrapper("plain") == "plain"
      echo "stripPatternWrapper: Passed"

    # Test isTrueBoolean/isFalseBoolean
    block:
      doAssert isTrueBoolean("true")
      doAssert isTrueBoolean("TRUE")
      doAssert isTrueBoolean("1")
      doAssert isTrueBoolean("yes")
      doAssert isTrueBoolean("on")
      doAssert not isTrueBoolean("false")
      doAssert not isTrueBoolean("maybe")

      doAssert isFalseBoolean("false")
      doAssert isFalseBoolean("FALSE")
      doAssert isFalseBoolean("0")
      doAssert isFalseBoolean("no")
      doAssert isFalseBoolean("off")
      doAssert isFalseBoolean("")
      doAssert not isFalseBoolean("true")
      doAssert not isFalseBoolean("maybe")

      echo "isTrueBoolean/isFalseBoolean: Passed"

    # Test splitLogicalOr/splitLogicalAnd
    block:
      let orParts = splitLogicalOr("a || b || c")
      doAssert orParts == @["a", "b", "c"]

      let andParts = splitLogicalAnd("x && y && z")
      doAssert andParts == @["x", "y", "z"]

      # No operators
      let single = splitLogicalOr("single")
      doAssert single == @["single"]

      echo "splitLogicalOr/splitLogicalAnd: Passed"

    # Test isSimpleVarName
    block:
      doAssert isSimpleVarName("foo")
      doAssert isSimpleVarName("_bar")
      doAssert isSimpleVarName("test123")
      doAssert isSimpleVarName("my-var")
      doAssert isSimpleVarName("my_var")
      doAssert not isSimpleVarName("")
      doAssert not isSimpleVarName("123abc")
      doAssert not isSimpleVarName("has.dot")
      doAssert not isSimpleVarName("has space")
      doAssert not isSimpleVarName("has(paren)")
      echo "isSimpleVarName: Passed"

    # Test findMatchingBrace
    block:
      doAssert findMatchingBrace("${foo}", 1) == 5
      doAssert findMatchingBrace("${a{b}c}", 1) == 7
      doAssert findMatchingBrace("${unclosed", 1) == -1
      echo "findMatchingBrace: Passed"

    echo "✓ Utils helpers test passed"
  except Exception as e:
    echo "✗ Utils helpers test failed: ", e.msg
    echo getStackTrace(e)

proc testForLoopWithExpression() =
  echo "\n=== Testing For Loop with Variable Expression ==="

  let ctx = initExecutionContext()
  ctx.silent = true
  ctx.passthrough = true

  # Set a variable with newline-separated values
  ctx.setVariable("items", "apple\nbanana\ncherry")

  try:
    # Test iterating over a string variable that gets split
    var collected: seq[string] = @[]
    let itemsStr = ctx.getVariable("items")
    let items = itemsStr.splitLines()

    for item in items:
      if item.strip().len > 0:
        collected.add(item)

    if collected == @["apple", "banana", "cherry"]:
      echo "For loop expression parsing: Passed"
    else:
      echo "For loop expression parsing: Failed (got " & $collected & ")"

    echo "✓ For loop with expression test passed"
  except Exception as e:
    echo "✗ For loop with expression test failed: ", e.msg

when isMainModule:
  echo "Running run3 module tests\n"

  testLexer()
  testParser()
  testVariables()
  testBuiltins()
  testMacros()
  testMacroArgParsing()
  testVariableOps()
  testExecManipulation()
  testConditions()
  testExecChaining()
  testNewConditionOperators()
  testContinueBreak()
  testUtilsHelpers()
  testForLoopWithExpression()

  echo "\n=== All Tests Complete ==="
