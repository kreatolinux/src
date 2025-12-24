import algorithm
import os
import strutils
import terminal
import ../../kpkg/modules/run3/lexer
import ../../kpkg/modules/run3/parser
import ../../kpkg/modules/run3/ast

const
  # Canonical order for variables
  variableOrder = [
    "name",
    "version",
    "release",
    "epoch",
    "description",
    "type",
    "sources",
    "sha256sum",
    "sha512sum",
    "b2sum",
    "extract",
    "depends",
    "build_depends",
    "replaces",
    "conflicts",
    "provides",
    "backup"
  ]

proc getVariableOrderIndex(name: string): int =
  ## Get the sort index for a variable name
  for i, v in variableOrder:
    if v == name:
      return i
  return variableOrder.len # Unknown variables go at the end

proc compareVariables(a, b: AstNode): int =
  ## Compare two variable nodes for sorting
  let aName = case a.kind
    of nkVariable: a.varName
    of nkListVariable: a.listName
    else: ""
  let bName = case b.kind
    of nkVariable: b.varName
    of nkListVariable: b.listName
    else: ""

  let aIdx = getVariableOrderIndex(aName)
  let bIdx = getVariableOrderIndex(bName)

  if aIdx < bIdx: return -1
  elif aIdx > bIdx: return 1
  else: return cmp(aName, bName)

proc sortVariables(variables: seq[AstNode]): seq[AstNode] =
  ## Sort variables in canonical order
  result = variables
  result.sort(compareVariables)

proc needsQuotes(s: string): bool =
  ## Check if a string needs quotes
  if s.len == 0:
    return true
  for c in s:
    if c in {' ', '\t', '"', '\'', ':', '#', '{', '}', '[', ']', '$', '\n'}:
      return true
  return false

proc escapeString(s: string): string =
  ## Escape special characters in a string
  result = ""
  for c in s:
    case c
    of '\n': result.add("\\n")
    of '\t': result.add("\\t")
    of '\r': result.add("\\r")
    of '\\': result.add("\\\\")
    of '"': result.add("\\\"")
    else: result.add(c)

proc formatValue(s: string): string =
  ## Format a value, quoting if necessary
  if needsQuotes(s):
    return "\"" & escapeString(s) & "\""
  return s

proc formatVariable(node: AstNode): string =
  ## Format a single variable declaration
  case node.kind
  of nkVariable:
    let op = case node.varOp
      of opSet: ":"
      of opAppend: "+:"
      of opRemove: "-:"
    return node.varName & op & " " & formatValue(node.varValue)

  of nkListVariable:
    let op = case node.listOp
      of opSet: ":"
      of opAppend: "+:"
      of opRemove: "-:"

    if node.listItems.len == 0:
      return node.listName & op
    elif node.listItems.len == 1 and not node.listItems[0].contains("\n"):
      # Single item can be on same line
      return node.listName & op & "\n  - " & formatValue(node.listItems[0])
    else:
      result = node.listName & op
      for item in node.listItems:
        result.add("\n  - " & formatValue(item))

  else:
    return ""

proc formatStatement(node: AstNode, indent: int): string =
  ## Format a single statement with given indentation
  let indentStr = "  ".repeat(indent)

  case node.kind
  of nkExec:
    # execCmd comes from parseExpression which already includes quotes
    return indentStr & "exec " & node.execCmd

  of nkMacro:
    result = indentStr & "macro " & node.macroName
    for arg in node.macroArgs:
      result.add(" " & arg)

  of nkPrint:
    # printText comes from parseExpression which already includes quotes
    return indentStr & "print " & node.printText

  of nkCd:
    # cdPath comes from parseExpression which already includes quotes
    return indentStr & "cd " & node.cdPath

  of nkEnv:
    # envValue comes from parseExpression which already includes quotes
    return indentStr & "env " & node.envVar & " = " & node.envValue

  of nkLocal:
    # localValue comes from parseExpression which already includes quotes
    return indentStr & "local " & node.localVar & " = " & node.localValue

  of nkGlobal:
    # globalValue comes from parseExpression which already includes quotes
    return indentStr & "global " & node.globalVar & " = " & node.globalValue

  of nkWrite:
    return indentStr & "write " & formatValue(node.writePath) & " " &
        node.writeContent

  of nkAppend:
    return indentStr & "append " & formatValue(node.appendPath) & " " &
        node.appendContent

  of nkIf:
    result = indentStr & "if " & node.condition & " {\n"
    for stmt in node.thenBranch:
      result.add(formatStatement(stmt, indent + 1) & "\n")
    result.add(indentStr & "}")
    if node.elseBranch.len > 0:
      result.add(" else {\n")
      for stmt in node.elseBranch:
        result.add(formatStatement(stmt, indent + 1) & "\n")
      result.add(indentStr & "}")

  of nkFor:
    if node.iterListLiteral.len > 0:
      result = indentStr & "for " & node.iterVar & " in ["
      for i, item in node.iterListLiteral:
        if i > 0:
          result.add(", ")
        result.add(formatValue(item))
      result.add("] {\n")
    else:
      result = indentStr & "for " & node.iterVar & " in " & node.iterList & " {\n"
    for stmt in node.forBody:
      result.add(formatStatement(stmt, indent + 1) & "\n")
    result.add(indentStr & "}")

  of nkFuncCall:
    result = indentStr & node.callName
    for arg in node.callArgs:
      result.add(" " & arg)

  of nkContinue:
    return indentStr & "continue"

  of nkBreak:
    return indentStr & "break"

  else:
    return ""

proc formatFunction(node: AstNode): string =
  ## Format a function definition
  case node.kind
  of nkFunction:
    result = node.funcName & " {\n"
    for stmt in node.funcBody:
      result.add(formatStatement(stmt, 1) & "\n")
    result.add("}")

  of nkCustomFunc:
    result = "func " & node.customFuncName & " {\n"
    for stmt in node.customFuncBody:
      result.add(formatStatement(stmt, 1) & "\n")
    result.add("}")

  else:
    return ""

proc formatRunfile(parsed: ParsedRunfile, sortVars: bool): string =
  ## Format a complete runfile
  result = ""

  # Format variables
  let variables = if sortVars: sortVariables(
      parsed.variables) else: parsed.variables
  for varNode in variables:
    result.add(formatVariable(varNode) & "\n")

  # Add blank line between variables and functions
  if parsed.variables.len > 0 and (parsed.functions.len > 0 or
      parsed.customFuncs.len > 0):
    result.add("\n")

  # Format custom functions first
  for i, funcNode in parsed.customFuncs:
    if i > 0:
      result.add("\n")
    result.add(formatFunction(funcNode) & "\n")

  # Add blank line between custom functions and regular functions
  if parsed.customFuncs.len > 0 and parsed.functions.len > 0:
    result.add("\n")

  # Format regular functions
  for i, funcNode in parsed.functions:
    if i > 0:
      result.add("\n")
    result.add(formatFunction(funcNode) & "\n")

proc formatFile(path: string, check: bool, sortVars: bool): tuple[changed: bool,
    error: string] =
  ## Format a single run3 file
  ## Returns (changed, error) - changed is true if file was modified (or would be in check mode)

  # Try to parse the file
  try:
    let content = readFile(path)
    let tokens = tokenize(content)
    var p = initParser(tokens)
    let parsed = p.parse()

    let formatted = formatRunfile(parsed, sortVars)

    if formatted != content:
      if check:
        return (true, "")
      else:
        writeFile(path, formatted)
        return (true, "")
    else:
      return (false, "")

  except IOError as e:
    return (false, "cannot read file: " & e.msg)
  except ParseError as e:
    return (false, "parse error at line " & $e.line & ": " & e.msg)
  except CatchableError as e:
    return (false, "unexpected error: " & e.msg)

proc fmt*(path = ".", recursive = true, check = false, sortVars = true): int =
  ## Format run3 runfiles.
  ## Returns 0 if successful (or no changes needed), 1 if errors or check found changes.
  var totalChanged = 0
  var totalErrors = 0
  var filesChecked = 0

  let absPath = absolutePath(path)

  proc processFile(filePath: string) =
    let (changed, error) = formatFile(filePath, check, sortVars)
    filesChecked += 1
    if error.len > 0:
      totalErrors += 1
      styledEcho(fgRed, "error", fgDefault, ": ", filePath, ": ", error)
    elif changed:
      totalChanged += 1
      if check:
        styledEcho(fgYellow, "would reformat", fgDefault, ": ", filePath)
      else:
        styledEcho(fgGreen, "formatted", fgDefault, ": ", filePath)

  if fileExists(absPath):
    # Single file
    processFile(absPath)
  elif dirExists(absPath):
    # Check for run3 file in directory
    let run3Path = absPath / "run3"
    let runPath = absPath / "run"

    if fileExists(run3Path):
      processFile(run3Path)
    elif fileExists(runPath):
      processFile(runPath)
    elif recursive:
      # Walk subdirectories
      for entry in walkDir(absPath):
        if entry.kind == pcDir and not isHidden(entry.path):
          let subRun3 = entry.path / "run3"
          let subRun = entry.path / "run"

          if fileExists(subRun3):
            processFile(subRun3)
          elif fileExists(subRun):
            processFile(subRun)
    else:
      styledEcho(fgRed, "error", fgDefault,
          ": no run3 or run file found in: ", absPath)
      return 1
  else:
    styledEcho(fgRed, "error", fgDefault, ": path does not exist: ", absPath)
    return 1

  # Summary
  if filesChecked == 0:
    echo "No run3 files found to format"
    return 0

  echo ""
  if totalErrors > 0:
    styledEcho(fgRed, $totalErrors, " error(s)", fgDefault,
        " in ", $filesChecked, " file(s)")
    return 1
  elif check and totalChanged > 0:
    styledEcho(fgYellow, $totalChanged, " file(s) would be reformatted", fgDefault)
    return 1
  elif totalChanged > 0:
    styledEcho(fgGreen, $totalChanged, " file(s) formatted", fgDefault)
    return 0
  else:
    styledEcho(fgGreen, "All files already formatted", fgDefault)
    return 0
