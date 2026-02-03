## Shared utilities for Kongue scripting language
## Contains common constants, regex patterns, helper functions, and logging shims

import regex
import strutils

# Logging shims for standalone Kongue
# These can be overridden by setting custom procs at runtime
var
  debugProc*: proc(msg: string) {.nimcall.} = nil
  warnProc*: proc(msg: string) {.nimcall.} = nil
  errorProc*: proc(msg: string) {.nimcall.} = nil

proc debug*(msg: string) =
  ## Debug logging - no-op by default, can be enabled by setting debugProc
  if debugProc != nil:
    debugProc(msg)

proc warn*(msg: string) =
  ## Warning logging - prints to stderr by default
  if warnProc != nil:
    warnProc(msg)
  else:
    stderr.writeLine("[warn] " & msg)

proc error*(msg: string) =
  ## Error logging - prints to stderr by default
  if errorProc != nil:
    errorProc(msg)
  else:
    stderr.writeLine("[error] " & msg)

# Safety limits for parsing/execution
const
  maxIterations* = 10000
  maxRecursionDepth* = 10
  maxStringLen* = 1000000
  maxTokens* = 100000
  maxStatements* = 10000
  maxArgs* = 1000
  maxItems* = 10000

# Regex patterns for variable resolution
# Note: These handle simple cases; complex nested expressions need manual parsing
let
  varSimplePattern* = re2(r"\$([a-zA-Z_][a-zA-Z0-9_]*|\d+)") # $varname or $0, $1, etc.

# Regex patterns for condition parsing
# These capture: left operand, operator, right operand
let
  conditionOpPattern* = re2(r"^(.+?)\s*(=~|==|!=)\s*(.+)$") # matches: left op right

# Boolean value sets
const
  trueBooleans* = ["true", "1", "yes", "y", "on"]
  falseBooleans* = ["false", "0", "no", "n", "off", ""]

proc stripQuotes*(s: string): string =
  ## Strip outer quotes if present (single or double)
  if s.len >= 2 and ((s[0] == '"' and s[^1] == '"') or (s[0] == '\'' and s[
      ^1] == '\'')):
    return s[1..^2]
  return s

proc findMatchingBrace*(text: string, start: int): int =
  ## Find the position of the closing brace matching the opening brace at start
  ## Returns -1 if not found
  ## Assumes text[start] == '{' or text[start-1..start] == "${"
  var braceCount = 1
  var i = start
  if i < text.len and text[i] == '$':
    i += 1
  if i < text.len and text[i] == '{':
    i += 1
  else:
    return -1

  while i < text.len and braceCount > 0:
    if text[i] == '{':
      braceCount += 1
    elif text[i] == '}':
      braceCount -= 1
    i += 1

  if braceCount == 0:
    return i - 1 # Position of closing brace
  return -1

proc extractBraceExpr*(text: string, start: int): tuple[expr: string, endPos: int] =
  ## Extract expression from ${...} starting at position of $
  ## Returns the expression (without ${}) and the position after }
  if start + 1 >= text.len or text[start] != '$' or text[start + 1] != '{':
    return ("", start)

  let closingPos = findMatchingBrace(text, start + 1)
  if closingPos == -1:
    return ("", start)

  result.expr = text[start + 2 ..< closingPos]
  result.endPos = closingPos + 1

proc isSimpleVarName*(expr: string): bool =
  ## Check if expression is a simple variable name (no methods, indexing, or special chars)
  if expr.len == 0:
    return false

  # First char must be letter or underscore
  if not (expr[0].isAlphaAscii() or expr[0] == '_'):
    return false

  # Rest must be alphanumeric, underscore, or dash
  for i in 1 ..< expr.len:
    let c = expr[i]
    if not (c.isAlphaNumeric() or c == '_' or c == '-'):
      return false

  return true

proc replaceSimpleVars*(text: string, getVar: proc(
    name: string): string): string =
  ## Replace simple $varname references using regex
  ## Does NOT handle ${...} expressions
  result = text
  var matches: RegexMatch2
  var offset = 0

  while offset < result.len:
    let searchText = result[offset..^1]
    if searchText.find(varSimplePattern, matches):
      let matchStart = offset + matches.boundaries.a
      let matchEnd = offset + matches.boundaries.b
      let varName = searchText[matches.group(0)]

      # Make sure this isn't part of ${...}
      if matchStart > 0 and result[matchStart - 1] == '{':
        offset = matchEnd + 1
        continue

      let value = getVar(varName)
      result = result[0 ..< matchStart] & value & result[matchEnd + 1 .. ^1]
      offset = matchStart + value.len
    else:
      break

type
  ConditionParts* = object
    ## Parsed condition with operator
    left*: string
    op*: string
    right*: string
    valid*: bool

proc parseConditionOperator*(condition: string): ConditionParts =
  ## Parse a condition string into left, operator, right parts using regex
  ## Returns valid=false if no operator found
  var matches: RegexMatch2
  if condition.find(conditionOpPattern, matches):
    result.left = condition[matches.group(0)].strip()
    result.op = condition[matches.group(1)]
    result.right = condition[matches.group(2)].strip()
    result.valid = true
  else:
    result.valid = false

proc stripPatternWrapper*(pattern: string): string =
  ## Strip e"..." or e'...' or regular quotes from regex pattern
  result = pattern
  if result.startsWith("e\"") and result.endsWith("\""):
    result = result[2..^2]
  elif result.startsWith("e'") and result.endsWith("'"):
    result = result[2..^2]
  elif result.startsWith("\"") and result.endsWith("\""):
    result = result[1..^2]
  elif result.startsWith("'") and result.endsWith("'"):
    result = result[1..^2]

proc isTrueBoolean*(s: string): bool =
  ## Check if string represents a true boolean value
  s.toLowerAscii() in trueBooleans

proc isFalseBoolean*(s: string): bool =
  ## Check if string represents a false boolean value
  s.toLowerAscii() in falseBooleans

proc splitLogicalOr*(condition: string): seq[string] =
  ## Split condition by || operator
  result = condition.split("||")
  for i in 0 ..< result.len:
    result[i] = result[i].strip()

proc splitLogicalAnd*(condition: string): seq[string] =
  ## Split condition by && operator
  result = condition.split("&&")
  for i in 0 ..< result.len:
    result[i] = result[i].strip()
