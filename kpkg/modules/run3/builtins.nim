## Built-in commands for run3 format
## Implements: exec, print, cd, env, local, global

import os
import osproc
import regex
import strutils
import strtabs
import tables
import ast
import lexer
import variables
import ../commonPaths
import ../processes
import ../logger

type
  ExecutionContext* = ref object
    ## Context for executing run3 code
    variables*: Table[string, string]          # Global variables from header
    listVariables*: Table[string, seq[string]] # List variables
    localVars*: Table[string, string]          # Function-local variables
    envVars*: Table[string, string]            # Environment variable overrides
    customFuncs*: Table[string, seq[AstNode]]  # Custom function bodies
    currentDir*: string                        # Current working directory
    destDir*: string                           # DESTDIR for installation
    srcDir*: string                            # Source directory
    buildRoot*: string                         # Build root directory
    packageName*: string                       # Package name
    silent*: bool                              # Suppress output
    passthrough*: bool                         # Passthrough execution (no sandbox)
    sandboxPath*: string                       # Sandbox root path
    remount*: bool                             # Remount sandbox

proc initExecutionContext*(destDir: string = "", srcDir: string = "",
        buildRoot: string = "", packageName: string = ""): ExecutionContext =
  ## Initialize a new execution context
  result = ExecutionContext()
  result.variables = initTable[string, string]()
  result.listVariables = initTable[string, seq[string]]()
  result.localVars = initTable[string, string]()
  result.envVars = initTable[string, string]()
  result.customFuncs = initTable[string, seq[AstNode]]()
  # Use srcDir for currentDir if provided (supports autocd from buildcmd)
  if srcDir != "":
    result.currentDir = srcDir
  else:
    result.currentDir = getCurrentDir()
  result.destDir = destDir
  result.srcDir = srcDir
  result.buildRoot = buildRoot
  result.packageName = packageName
  result.silent = false
  result.passthrough = false
  result.sandboxPath = kpkgMergedPath
  result.remount = false

proc setVariable*(ctx: ExecutionContext, name: string, value: string) =
  ## Set a global variable
  ctx.variables[name] = value

proc setListVariable*(ctx: ExecutionContext, name: string, items: seq[string]) =
  ## Set a list variable
  ctx.listVariables[name] = items

proc getVariable*(ctx: ExecutionContext, name: string): string =
  ## Get a variable value (checks local, then global, then built-in)
  if ctx.localVars.hasKey(name):
    return ctx.localVars[name]
  if ctx.variables.hasKey(name):
    return ctx.variables[name]
  # Check environment variables
  if ctx.envVars.hasKey(name):
    return ctx.envVars[name]
  # Check built-in variables
  case name
  of "ROOT":
    return ctx.buildRoot
  of "DESTDIR":
    return ctx.destDir
  of "SRCDIR":
    return ctx.srcDir
  of "PACKAGENAME":
    return ctx.packageName
  else:
    return ""

proc getListVariable*(ctx: ExecutionContext, name: string): seq[string] =
  ## Get a list variable
  if ctx.listVariables.hasKey(name):
    return ctx.listVariables[name]
  return @[]

proc hasVariable*(ctx: ExecutionContext, name: string): bool =
  ## Check if a variable exists
  if ctx.localVars.hasKey(name) or ctx.variables.hasKey(name) or
          ctx.envVars.hasKey(name):
    return true
  # Check built-in variables
  case name
  of "ROOT", "DESTDIR", "SRCDIR", "PACKAGENAME":
    return true
  else:
    return false

proc hasListVariable*(ctx: ExecutionContext, name: string): bool =
  ## Check if a list variable exists
  return ctx.listVariables.hasKey(name)

proc resolveVariables*(ctx: ExecutionContext, text: string,
    depth: int = 0): string

proc execCapture(ctx: ExecutionContext, command: string, depth: int = 0): tuple[output: string,
        exitCode: int] =
  ## Execute a command and capture output
  if depth > 10:
    warn("execCapture: maximum recursion depth exceeded, returning empty")
    return ("", 1)

  let resolvedCmd = ctx.resolveVariables(command, depth + 1)
  if not ctx.silent:
    echo "[exec capture] " & resolvedCmd

  # Use execEnvCapture for sandboxed execution

  # Build environment variable exports for the command
  var cmdParts: seq[string] = @[]

  # Add custom environment variables
  for key, val in ctx.envVars:
    cmdParts.add("export " & key & "=" & quoteShell(val))

  # Add standard build variables
  if ctx.destDir != "":
    cmdParts.add("export DESTDIR=" & quoteShell(ctx.destDir))
    if ctx.buildRoot != "":
      cmdParts.add("export ROOT=" & quoteShell(ctx.buildRoot))
  if ctx.srcDir != "":
    cmdParts.add("export SRCDIR=" & quoteShell(ctx.srcDir))
  if ctx.packageName != "":
    cmdParts.add("export PACKAGENAME=" & quoteShell(ctx.packageName))

  # Add cd command
  cmdParts.add("cd " & quoteShell(ctx.currentDir))

  # Add the actual command
  cmdParts.add(resolvedCmd)

  # Combine environment setup with the actual command using &&
  let fullCmd = cmdParts.join(" && ")

  return execEnv(fullCmd, "none", ctx.passthrough, ctx.silent,
          ctx.sandboxPath, ctx.remount)


proc resolveManipulation(ctx: ExecutionContext, expr: string,
    depth: int = 0): string =
  ## Resolve a complex variable manipulation expression
  ## expr is the content inside ${...}
  if depth > 10:
    warn("resolveManipulation: maximum recursion depth exceeded, returning empty")
    return ""

  let tokens = tokenize(expr)
  var p = 0
  const maxIterations = 10000 # Safety limit to prevent infinite loops

  proc peek(): Token =
    if p < tokens.len: tokens[p] else: Token(kind: tkEof)

  proc advance(): Token =
    result = peek()
    p += 1

  # Parse base
  var baseValue: VarValue
  var iterations = 0

  if peek().kind == tkExec:
    # exec("cmd")
    discard advance() # exec
    discard advance() # (
    let cmd = advance().value # string
    discard advance() # )
    
        # Execute immediately
    let (output, exitCode) = ctx.execCapture(cmd, depth + 1)

    # Look ahead for .output() or .exit()
    if peek().kind == tkDot:
      discard advance() # .
      let methodTok = advance()
      let methodName = methodTok.value

      discard advance() # (
      discard advance() # )

      if methodName == "output":
        baseValue = newStringValue(output)
      elif methodName == "exit":
        baseValue = newStringValue($exitCode)
      else:
        baseValue = newStringValue(output)
        # Apply the method to the output string
        try:
          let methods = @[VarManipMethod(name: methodName, args: @[])]
          baseValue = evaluateVarManipulation(baseValue, methods, "")
        except ValueError:
          # Ignore if method invalid for string
          discard
    else:
      baseValue = newStringValue(output)

  else:
    # Variable
    let varName = advance().value
    if ctx.hasListVariable(varName):
      baseValue = newListValue(ctx.getListVariable(varName))
    else:
      baseValue = newStringValue(ctx.getVariable(varName))

  # Parse method chain
  var methods: seq[VarManipMethod] = @[]
  var indexExpr = ""

  while peek().kind == tkDot:
    iterations += 1
    if iterations > maxIterations:
      warn("too many iterations in resolveManipulation, aborting")
      break
    discard advance() # .
    let methodName = peek().value
    discard advance()

    var args: seq[string] = @[]
    if peek().kind == tkLParen:
      discard advance() # (
      while peek().kind != tkRParen and peek().kind != tkEof:
        iterations += 1
        if iterations > maxIterations:
          warn("too many iterations in resolveManipulation args, aborting")
          break
        if peek().kind == tkString or peek().kind == tkIdentifier or
                peek().kind == tkNumber:
          args.add(advance().value)
        elif peek().kind == tkComma:
          discard advance()
        else:
          discard advance()
      discard advance() # )

    methods.add(VarManipMethod(name: methodName, args: args))

  if peek().kind == tkLBracket:
    discard advance() # [
        # Read index expr
    while peek().kind != tkRBracket and peek().kind != tkEof:
      iterations += 1
      if iterations > maxIterations:
        warn("too many iterations in resolveManipulation index, aborting")
        break
      indexExpr.add(advance().value)
    discard advance() # ]

  try:
    let res = evaluateVarManipulation(baseValue, methods, indexExpr)
    return res.toString()
  except ValueError:
    return ""

proc resolveVariables*(ctx: ExecutionContext, text: string,
    depth: int = 0): string =
  ## Resolve variable references in text
  ## Handles $var and ${var} syntax
  if depth > 10:
    warn("resolveVariables: maximum recursion depth exceeded, returning original text")
    return text

  result = text

  # Replace ${var} first
  var i = 0
  while i < result.len:
    if i < result.len - 1 and result[i] == '$' and result[i+1] == '{':
      # Find the closing }
      var j = i + 2
      var braceCount = 1
      while j < result.len and braceCount > 0:
        if result[j] == '{':
          braceCount += 1
        elif result[j] == '}':
          braceCount -= 1
        j += 1

      if braceCount == 0:
        let varExpr = result[i+2..<j-1]
        let value = ctx.resolveManipulation(varExpr, depth + 1)
        result = result[0..<i] & value & result[j..^1]
        i += value.len
      else:
        i += 1
    else:
      i += 1

  # Replace $var
  i = 0
  while i < result.len:
    if result[i] == '$':
      var j = i + 1
      while j < result.len and (result[j].isAlphaNumeric() or result[j] == '_'):
        j += 1

      if j > i + 1:
        let varName = result[i+1..<j]
        let value = ctx.getVariable(varName)
        result = result[0..<i] & value & result[j..^1]
        i += value.len
      else:
        i += 1
    else:
      i += 1

proc stripQuotes*(s: string): string =
  ## Strip outer quotes if present
  if s.len >= 2 and ((s[0] == '"' and s[^1] == '"') or (s[0] == '\'' and s[
          ^1] == '\'')):
    return s[1..^2]
  return s

proc builtinExec*(ctx: ExecutionContext, command: string): int =
  ## Execute a shell command
  # Strip outer quotes if the parser wrapped the command in quotes
  # This happens when exec "command" is parsed - the parser adds quotes
  # but the shell wrapper in execEnv will add its own quotes
  let resolvedCmd = stripQuotes(ctx.resolveVariables(command))

  # Execute command
  if not ctx.silent:
    echo "[exec] " & resolvedCmd

  # Determine execution function to use
  let executor = execEnv

  # Build environment variable exports for the command
  var cmdParts: seq[string] = @[]

  # Add custom environment variables
  for key, val in ctx.envVars:
    cmdParts.add("export " & key & "=" & quoteShell(val))

  # Add standard build variables
  if ctx.destDir != "":
    cmdParts.add("export DESTDIR=" & quoteShell(ctx.destDir))
    if ctx.buildRoot != "":
      cmdParts.add("export ROOT=" & quoteShell(ctx.buildRoot))
  if ctx.srcDir != "":
    cmdParts.add("export SRCDIR=" & quoteShell(ctx.srcDir))
  if ctx.packageName != "":
    cmdParts.add("export PACKAGENAME=" & quoteShell(ctx.packageName))

  # Add cd command
  cmdParts.add("cd " & quoteShell(ctx.currentDir))

  # Add the actual command
  cmdParts.add(resolvedCmd)

  # Combine environment setup with the actual command using &&
  let fullCmd = cmdParts.join(" && ")

  debug "builtinExec: sandboxPath=" & ctx.sandboxPath & ", passthrough=" &
      $ctx.passthrough
  debug "builtinExec: fullCmd=" & fullCmd

  let execResult = executor(fullCmd, "none", ctx.passthrough, ctx.silent,
          ctx.sandboxPath, ctx.remount)

  debug "builtinExec: exitCode=" & $execResult.exitCode
  result = execResult.exitCode

proc builtinPrint*(ctx: ExecutionContext, text: string) =
  ## Print text to stdout
  let resolved = ctx.resolveVariables(text)
  if not ctx.silent:
    echo resolved

proc builtinCd*(ctx: ExecutionContext, path: string): bool =
  ## Change current directory
  let resolvedPath = ctx.resolveVariables(path)

  # Handle relative paths
  var fullPath = resolvedPath
  if not isAbsolute(resolvedPath):
    fullPath = ctx.currentDir / resolvedPath

  if dirExists(fullPath):
    ctx.currentDir = fullPath
    return true
  else:
    echo "Error: Directory does not exist: " & fullPath
    return false

proc builtinEnv*(ctx: ExecutionContext, varName: string, value: string) =
  ## Set an environment variable for subsequent exec commands
  let resolvedValue = stripQuotes(ctx.resolveVariables(value))
  ctx.envVars[varName] = resolvedValue

proc builtinLocal*(ctx: ExecutionContext, varName: string, value: string) =
  ## Set a local variable (function scope)
  let resolvedValue = stripQuotes(ctx.resolveVariables(value))
  ctx.localVars[varName] = resolvedValue

proc builtinGlobal*(ctx: ExecutionContext, varName: string, value: string) =
  ## Set a global variable
  let resolvedValue = stripQuotes(ctx.resolveVariables(value))
  ctx.variables[varName] = resolvedValue

proc builtinWrite*(ctx: ExecutionContext, path: string, content: string) =
  ## Write content to a file
  let resolvedPath = ctx.resolveVariables(path)
  let resolvedContent = stripQuotes(ctx.resolveVariables(content))

  # Determine full path
  var fullPath = resolvedPath
  if not isAbsolute(resolvedPath):
    fullPath = ctx.currentDir / resolvedPath

  try:
    writeFile(fullPath, resolvedContent)
    if not ctx.silent:
      echo "[write] " & fullPath
  except IOError as e:
    echo "Error writing to file " & fullPath & ": " & e.msg

proc builtinAppend*(ctx: ExecutionContext, path: string, content: string) =
  ## Append content to a file
  let resolvedPath = ctx.resolveVariables(path)
  let resolvedContent = stripQuotes(ctx.resolveVariables(content))

  # Determine full path
  var fullPath = resolvedPath
  if not isAbsolute(resolvedPath):
    fullPath = ctx.currentDir / resolvedPath

  try:
    var f = open(fullPath, fmAppend)
    f.write(resolvedContent)
    f.close()
    if not ctx.silent:
      echo "[append] " & fullPath
  except IOError as e:
    echo "Error appending to file " & fullPath & ": " & e.msg

proc clearLocalVars*(ctx: ExecutionContext) =
  ## Clear all local variables (called when exiting a function)
  ctx.localVars.clear()

proc evaluateSingleCondition(ctx: ExecutionContext, condition: string): bool =
  ## Evaluate a single condition (no || or &&)
  ## Supports:
  ## - Variable existence checks ($var)
  ## - Boolean literals (true, yes, 1)
  ## - Equality checks ($var == "value")
  ## - Inequality checks ($var != "value")
  ## - Regex matching ($var =~ e"pattern")
  ## - Existence/Non-empty checks (if $var)
  let resolved = ctx.resolveVariables(condition).strip()

  # Check for regex match operator =~
  if "=~" in resolved:
    let parts = resolved.split("=~")
    if parts.len == 2:
      let leftVal = parts[0].strip().strip(chars = {'"', '\''})
      var pattern = parts[1].strip()
      # Strip e"..." wrapper if present
      if pattern.startsWith("e\"") and pattern.endsWith("\""):
        pattern = pattern[2..^2]
      elif pattern.startsWith("e'") and pattern.endsWith("'"):
        pattern = pattern[2..^2]
      elif pattern.startsWith("\"") and pattern.endsWith("\""):
        pattern = pattern[1..^2]
      elif pattern.startsWith("'") and pattern.endsWith("'"):
        pattern = pattern[1..^2]
      try:
        # Use ^ and $ anchors for full match by default
        return leftVal.match(re2("^(" & pattern & ")$"))
      except:
        warn("Invalid regex pattern: " & pattern)
        return false

  # Check for equality operators
  if "==" in resolved:
    let parts = resolved.split("==")
    if parts.len == 2:
      return parts[0].strip().strip(chars = {'"', '\''}) == parts[1].strip(
        ).strip(chars = {'"', '\''})
  elif "!=" in resolved:
    let parts = resolved.split("!=")
    if parts.len == 2:
      return parts[0].strip().strip(chars = {'"', '\''}) != parts[1].strip(
        ).strip(chars = {'"', '\''})

  # Check for boolean-like values
  if resolved.toLowerAscii() in ["true", "1", "yes", "y", "on"]:
    return true
  if resolved.toLowerAscii() in ["false", "0", "no", "n", "off", ""]:
    return false

  # Check if non-empty string
  return resolved.len > 0

proc evaluateCondition*(ctx: ExecutionContext, condition: string): bool =
  ## Evaluate a condition for if statements
  ## Supports:
  ## - || (OR) operator
  ## - && (AND) operator
  ## - == (equality)
  ## - != (inequality)
  ## - =~ (regex match) with e"pattern" syntax
  ## - Boolean literals (true, yes, 1)
  ## - Variable existence/non-empty checks

  let resolved = ctx.resolveVariables(condition).strip()

  # Handle || (OR) - split and evaluate, return true if any is true
  if "||" in resolved:
    let orParts = resolved.split("||")
    for part in orParts:
      if ctx.evaluateSingleCondition(part.strip()):
        return true
    return false

  # Handle && (AND) - split and evaluate, return true only if all are true
  if "&&" in resolved:
    let andParts = resolved.split("&&")
    for part in andParts:
      if not ctx.evaluateSingleCondition(part.strip()):
        return false
    return true

  # Single condition
  return ctx.evaluateSingleCondition(resolved)
