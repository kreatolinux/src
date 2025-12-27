import os
import strutils
import terminal
import ../../kpkg/modules/run3/lexer
import ../../kpkg/modules/run3/parser
import ../../kpkg/modules/run3/ast

type
  LintSeverity = enum
    lsError = "error"
    lsWarning = "warning"
    lsInfo = "info"

  LintIssue = object
    severity: LintSeverity
    line: int
    col: int
    message: string

proc addIssue(issues: var seq[LintIssue], severity: LintSeverity, line: int,
    message: string, col: int = 0) =
  issues.add(LintIssue(severity: severity, line: line, col: col,
      message: message))

proc lintVariables(parsed: ParsedRunfile, issues: var seq[LintIssue]) =
  ## Lint variable declarations
  var hasName = false
  var hasVersion = false
  var hasRelease = false
  var hasDescription = false
  var hasSources = false
  var hasChecksums = false

  for varNode in parsed.variables:
    case varNode.kind
    of nkVariable:
      case varNode.varName
      of "name":
        hasName = true
        if varNode.varValue.len == 0:
          issues.addIssue(lsError, varNode.line, "name cannot be empty")
      of "version":
        hasVersion = true
        if varNode.varValue.len == 0:
          issues.addIssue(lsError, varNode.line, "version cannot be empty")
      of "release":
        hasRelease = true
        if varNode.varValue.len == 0:
          issues.addIssue(lsError, varNode.line, "release cannot be empty")
        try:
          discard parseInt(varNode.varValue)
        except ValueError:
          issues.addIssue(lsWarning, varNode.line,
              "release should be a number, got: " & varNode.varValue)
      of "description":
        hasDescription = true
        if varNode.varValue.len == 0:
          issues.addIssue(lsWarning, varNode.line, "description is empty")
      of "epoch":
        if varNode.varValue != "no":
          try:
            discard parseInt(varNode.varValue)
          except ValueError:
            issues.addIssue(lsWarning, varNode.line,
                "epoch should be a number or 'no', got: " & varNode.varValue)
      of "extract":
        if varNode.varValue.toLowerAscii() notin ["true", "false", "1", "0",
            "yes", "no", "y", "n", "on", "off"]:
          issues.addIssue(lsWarning, varNode.line,
              "extract should be a boolean value, got: " & varNode.varValue)
      of "type":
        if varNode.varValue notin ["group", "meta", "normal", ""]:
          issues.addIssue(lsInfo, varNode.line,
              "unusual package type: " & varNode.varValue)
      else:
        discard

    of nkListVariable:
      case varNode.listName
      of "sources":
        hasSources = true
        if varNode.listItems.len == 0:
          issues.addIssue(lsInfo, varNode.line,
              "sources list is empty (meta/group package?)")
      of "sha256sum", "sha512sum", "b2sum":
        hasChecksums = true
        for item in varNode.listItems:
          if item == "SKIP":
            issues.addIssue(lsInfo, varNode.line,
                "checksum verification is skipped for one or more sources")
            break
      of "depends", "build_depends":
        for item in varNode.listItems:
          if item.contains(" "):
            issues.addIssue(lsError, varNode.line,
                "dependency name contains spaces: " & item)
      of "replaces", "conflicts", "provides":
        discard
      else:
        discard

    else:
      discard

  # Check required fields
  if not hasName:
    issues.addIssue(lsError, 0, "missing required variable: name")
  if not hasVersion:
    issues.addIssue(lsError, 0, "missing required variable: version")
  if not hasRelease:
    issues.addIssue(lsError, 0, "missing required variable: release")
  if not hasDescription:
    issues.addIssue(lsWarning, 0, "missing recommended variable: description")
  if hasSources and not hasChecksums:
    issues.addIssue(lsWarning, 0,
        "sources defined but no checksums (sha256sum/sha512sum/b2sum)")

proc lintStatement(node: AstNode, issues: var seq[LintIssue], funcName: string,
    customFuncs: seq[string]) =
  ## Lint a single statement
  case node.kind
  of nkExec:
    if node.execCmd.len == 0:
      issues.addIssue(lsError, node.line, "empty exec command")
    # Check for potentially unsafe patterns
    if "rm -rf /" in node.execCmd or "rm -rf /*" in node.execCmd:
      issues.addIssue(lsError, node.line,
          "potentially dangerous command: " & node.execCmd)

  of nkMacro:
    if node.macroName.len == 0:
      issues.addIssue(lsError, node.line, "empty macro name")

  of nkIf:
    if node.condition.len == 0:
      issues.addIssue(lsError, node.line, "empty if condition")
    for stmt in node.thenBranch:
      lintStatement(stmt, issues, funcName, customFuncs)
    for stmt in node.elseBranch:
      lintStatement(stmt, issues, funcName, customFuncs)

  of nkFor:
    if node.iterVar.len == 0:
      issues.addIssue(lsError, node.line, "empty for loop iterator variable")
    if node.iterList.len == 0 and node.iterListLiteral.len == 0:
      issues.addIssue(lsError, node.line, "empty for loop list")
    for stmt in node.forBody:
      lintStatement(stmt, issues, funcName, customFuncs)

  of nkFuncCall:
    if node.callName.len == 0:
      issues.addIssue(lsError, node.line, "empty function call name")
    # Check if calling a defined custom function
    if node.callName notin customFuncs:
      issues.addIssue(lsInfo, node.line,
          "calling undefined custom function: " & node.callName &
          " (may be defined elsewhere)")

  of nkLocal, nkGlobal:
    discard

  of nkEnv:
    if node.envVar.len == 0:
      issues.addIssue(lsError, node.line, "empty environment variable name")

  of nkCd:
    if node.cdPath.len == 0:
      issues.addIssue(lsWarning, node.line, "empty cd path")

  of nkWrite, nkAppend:
    discard

  of nkPrint:
    discard

  of nkContinue, nkBreak:
    discard

  else:
    discard

proc lintFunctions(parsed: ParsedRunfile, issues: var seq[LintIssue]) =
  ## Lint function definitions
  var hasBuild = false

  # Collect custom function names
  var customFuncs: seq[string] = @[]
  for funcNode in parsed.customFuncs:
    if funcNode.kind == nkCustomFunc:
      customFuncs.add(funcNode.customFuncName)

  # Lint regular functions
  for funcNode in parsed.functions:
    if funcNode.kind == nkFunction:
      if funcNode.funcName == "build":
        hasBuild = true

      if funcNode.funcBody.len == 0:
        issues.addIssue(lsInfo, funcNode.line,
            "function '" & funcNode.funcName & "' has empty body")

      for stmt in funcNode.funcBody:
        lintStatement(stmt, issues, funcNode.funcName, customFuncs)

  # Lint custom functions
  for funcNode in parsed.customFuncs:
    if funcNode.kind == nkCustomFunc:
      if funcNode.customFuncBody.len == 0:
        issues.addIssue(lsInfo, funcNode.line,
            "custom function '" & funcNode.customFuncName & "' has empty body")

      for stmt in funcNode.customFuncBody:
        lintStatement(stmt, issues, funcNode.customFuncName, customFuncs)

  # Check for build function (required for most packages)
  if not hasBuild:
    issues.addIssue(lsInfo, 0,
        "no 'build' function defined (may be intentional for meta packages)")

proc printIssues(issues: seq[LintIssue], path: string, verbose: bool): tuple[
    errors: int, warnings: int] =
  ## Print lint issues and return counts
  var errors = 0
  var warnings = 0

  for issue in issues:
    case issue.severity
    of lsError:
      errors += 1
      styledEcho(fgRed, "error", fgDefault, ": ", path, ":",
          $issue.line, ": ", issue.message)
    of lsWarning:
      warnings += 1
      styledEcho(fgYellow, "warning", fgDefault, ": ", path, ":",
          $issue.line, ": ", issue.message)
    of lsInfo:
      if verbose:
        styledEcho(fgBlue, "info", fgDefault, ": ", path, ":",
            $issue.line, ": ", issue.message)

  return (errors, warnings)

proc lintFile(path: string, verbose: bool): tuple[errors: int, warnings: int] =
  ## Lint a single run3 file
  var issues: seq[LintIssue] = @[]

  # Try to parse the file
  try:
    let content = readFile(path)
    let tokens = tokenize(content)
    var parser = initParser(tokens)
    let parsed = parser.parse()

    # Run linters
    lintVariables(parsed, issues)
    lintFunctions(parsed, issues)

  except IOError as e:
    issues.addIssue(lsError, 0, "cannot read file: " & e.msg)
  except ParseError as e:
    issues.addIssue(lsError, e.line, "parse error: " & e.msg)
  except CatchableError as e:
    issues.addIssue(lsError, 0, "unexpected error: " & e.msg)

  return printIssues(issues, path, verbose)

proc lint*(path = ".", recursive = true, verbose = false): int =
  ## Lint run3 runfiles for common issues.
  ## Returns 0 if no errors, 1 if errors found.
  var totalErrors = 0
  var totalWarnings = 0
  var filesChecked = 0

  let absPath = absolutePath(path)

  if fileExists(absPath):
    # Single file
    let (errors, warnings) = lintFile(absPath, verbose)
    totalErrors += errors
    totalWarnings += warnings
    filesChecked += 1
  elif dirExists(absPath):
    # Check for run3 file in directory
    let run3Path = absPath / "run3"
    let runPath = absPath / "run"

    if fileExists(run3Path):
      let (errors, warnings) = lintFile(run3Path, verbose)
      totalErrors += errors
      totalWarnings += warnings
      filesChecked += 1
    elif fileExists(runPath):
      let (errors, warnings) = lintFile(runPath, verbose)
      totalErrors += errors
      totalWarnings += warnings
      filesChecked += 1
    elif recursive:
      # Walk subdirectories
      for entry in walkDir(absPath):
        if entry.kind == pcDir and not isHidden(entry.path):
          let subRun3 = entry.path / "run3"
          let subRun = entry.path / "run"

          if fileExists(subRun3):
            let (errors, warnings) = lintFile(subRun3, verbose)
            totalErrors += errors
            totalWarnings += warnings
            filesChecked += 1
          elif fileExists(subRun):
            let (errors, warnings) = lintFile(subRun, verbose)
            totalErrors += errors
            totalWarnings += warnings
            filesChecked += 1
    else:
      styledEcho(fgRed, "error", fgDefault,
          ": no run3 or run file found in: ", absPath)
      return 1
  else:
    styledEcho(fgRed, "error", fgDefault, ": path does not exist: ", absPath)
    return 1

  # Summary
  if filesChecked == 0:
    echo "No run3 files found to lint"
    return 0

  echo ""
  if totalErrors > 0:
    styledEcho(fgRed, $totalErrors, " error(s)", fgDefault, " and ",
        fgYellow, $totalWarnings, " warning(s)", fgDefault,
        " in ", $filesChecked, " file(s)")
    return 1
  elif totalWarnings > 0:
    styledEcho(fgYellow, $totalWarnings, " warning(s)", fgDefault,
        " in ", $filesChecked, " file(s)")
    return 0
  else:
    styledEcho(fgGreen, "No issues found", fgDefault,
        " in ", $filesChecked, " file(s)")
    return 0
