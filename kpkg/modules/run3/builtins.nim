## Built-in commands for run3 format
## Implements: exec, print, cd, env, local, global

import os
import osproc
import regex
import strutils
import tables
import ast
import context
import lexer
import variables
import utils
import ../processes
import ../logger

export context
export utils.stripQuotes

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
          ctx.sandboxPath, ctx.remount, ctx.asRoot)


proc resolveManipulation(ctx: ExecutionContext, expr: string,
    depth: int = 0): string =
  ## Resolve a complex variable manipulation expression
  ## expr is the content inside ${...}
  if depth > 10:
    warn("resolveManipulation: maximum recursion depth exceeded, returning empty")
    return ""

  let tokens = tokenize(expr)
  var p = 0

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
  if depth > maxRecursionDepth:
    warn("resolveVariables: maximum recursion depth exceeded, returning original text")
    return text

  result = text

  # First pass: Replace ${...} expressions (may contain methods/indexing)
  var i = 0
  while i < result.len:
    if i < result.len - 1 and result[i] == '$' and result[i+1] == '{':
      let (varExpr, endPos) = extractBraceExpr(result, i)
      if varExpr.len > 0:
        let value = ctx.resolveManipulation(varExpr, depth + 1)
        result = result[0 ..< i] & value & result[endPos .. ^1]
        i += value.len
      else:
        i += 1
    else:
      i += 1

  # Second pass: Replace simple $varname references using regex helper
  result = replaceSimpleVars(result, proc(
      name: string): string = ctx.getVariable(name))

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

  # Helper to escape values for use within double quotes
  # Need to escape: $ ` " \ and newlines
  proc escapeForDoubleQuote(s: string): string =
    result = ""
    for c in s:
      case c
      of '$', '`', '"', '\\':
        result.add('\\')
        result.add(c)
      of '\n':
        result.add("\\n")
      else:
        result.add(c)

  # Add custom environment variables
  for key, val in ctx.envVars:
    cmdParts.add("export " & key & "=\"" & escapeForDoubleQuote(val) & "\"")

  # Add standard build variables
  if ctx.destDir != "":
    cmdParts.add("export DESTDIR=\"" & escapeForDoubleQuote(ctx.destDir) & "\"")
    if ctx.buildRoot != "":
      cmdParts.add("export ROOT=\"" & escapeForDoubleQuote(ctx.buildRoot) & "\"")
  if ctx.srcDir != "":
    cmdParts.add("export SRCDIR=\"" & escapeForDoubleQuote(ctx.srcDir) & "\"")
  if ctx.packageName != "":
    cmdParts.add("export PACKAGENAME=\"" & escapeForDoubleQuote(
        ctx.packageName) & "\"")

  # Add cd command
  cmdParts.add("cd \"" & escapeForDoubleQuote(ctx.currentDir) & "\"")

  # Add the actual command
  cmdParts.add(resolvedCmd)

  # Combine environment setup with the actual command using &&
  let fullCmd = cmdParts.join(" && ")

  debug "builtinExec: sandboxPath=" & ctx.sandboxPath & ", passthrough=" &
      $ctx.passthrough & ", asRoot=" & $ctx.asRoot
  debug "builtinExec: fullCmd=" & fullCmd

  let execResult = executor(fullCmd, "none", ctx.passthrough, ctx.silent,
          ctx.sandboxPath, ctx.remount, ctx.asRoot)

  debug "builtinExec: exitCode=" & $execResult.exitCode
  result = execResult.exitCode

proc builtinPrint*(ctx: ExecutionContext, text: string) =
  ## Print text to stdout
  let resolved = ctx.resolveVariables(text)
  if not ctx.silent:
    echo resolved

proc builtinCd*(ctx: ExecutionContext, path: string): bool =
  ## Change current directory
  let resolvedPath = stripQuotes(ctx.resolveVariables(path))

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
  let resolvedPath = stripQuotes(ctx.resolveVariables(path))
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
  let resolvedPath = stripQuotes(ctx.resolveVariables(path))
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

proc evaluateSingleCondition(ctx: ExecutionContext, condition: string): bool =
  ## Evaluate a single condition (no || or &&)
  ## Supports: ==, !=, =~ (regex), boolean literals, existence checks
  let resolved = ctx.resolveVariables(condition).strip()

  # Parse condition using regex pattern
  let parts = parseConditionOperator(resolved)
  if parts.valid:
    let leftVal = stripQuotes(parts.left)
    case parts.op
    of "=~":
      let pattern = stripPatternWrapper(parts.right)
      try:
        return leftVal.match(re2("^(" & pattern & ")$"))
      except:
        warn("Invalid regex pattern: " & pattern)
        return false
    of "==":
      return leftVal == stripQuotes(parts.right)
    of "!=":
      return leftVal != stripQuotes(parts.right)
    else:
      discard

  # Check for boolean-like values
  if isTrueBoolean(resolved):
    return true
  if isFalseBoolean(resolved):
    return false

  # Check if non-empty string
  return resolved.len > 0

proc evaluateCondition*(ctx: ExecutionContext, condition: string): bool =
  ## Evaluate a condition for if statements
  ## Supports: || (OR), && (AND), ==, !=, =~ (regex), boolean literals
  let resolved = ctx.resolveVariables(condition).strip()

  # Handle || (OR)
  if "||" in resolved:
    for part in splitLogicalOr(resolved):
      if ctx.evaluateSingleCondition(part):
        return true
    return false

  # Handle && (AND)
  if "&&" in resolved:
    for part in splitLogicalAnd(resolved):
      if not ctx.evaluateSingleCondition(part):
        return false
    return true

  # Single condition
  return ctx.evaluateSingleCondition(resolved)
