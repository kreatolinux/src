## Parser for run3 format
## Converts tokens into an AST

import strutils
import ast
import lexer
import ../logger

when not declared(readFile):
  import os

type
  Parser* = object
    ## Parser state
    tokens*: seq[Token]
    pos*: int

  ParseError* = object of CatchableError
    ## Parse error with line information
    line*: int
    col*: int

proc initParser*(tokens: seq[Token]): Parser =
  ## Initialize a new parser
  result.tokens = tokens
  result.pos = 0

proc peek(p: Parser, offset: int = 0): Token =
  ## Peek at a token without consuming it
  let pos = p.pos + offset
  if pos >= p.tokens.len:
    return Token(kind: tkEof, value: "", line: 0, col: 0)
  return p.tokens[pos]

proc advance(p: var Parser): Token =
  ## Consume and return the current token
  if p.pos >= p.tokens.len:
    return Token(kind: tkEof, value: "", line: 0, col: 0)
  result = p.tokens[p.pos]
  p.pos += 1

proc expect(p: var Parser, kind: TokenKind): Token =
  ## Expect a specific token kind, raise error if not found
  let tok = p.advance()
  if tok.kind != kind:
    var err = newException(ParseError, "Expected " & $kind & " but got " & $tok.kind)
    err.line = tok.line
    err.col = tok.col
    raise err
  return tok

proc skipNewlines(p: var Parser) =
  ## Skip newline tokens
  while p.peek().kind == tkNewline:
    discard p.advance()

proc skipCommentsAndNewlines(p: var Parser) =
  ## Skip comment and newline tokens
  while p.peek().kind in {tkNewline, tkComment}:
    discard p.advance()

proc parseString(p: var Parser): string =
  ## Parse a string value (with variable substitution support)
  let tok = p.peek()
  if tok.kind == tkString:
    discard p.advance()
    return tok.value
  elif tok.kind == tkIdentifier or tok.kind == tkNumber:
    discard p.advance()
    return tok.value
  else:
    var err = newException(ParseError, "Expected string but got " & $tok.kind)
    err.line = tok.line
    err.col = tok.col
    raise err

proc parseListItems(p: var Parser): seq[string] =
  ## Parse list items (lines starting with -)
  result = @[]
  p.skipNewlines()

  const maxItems = 10000 # Safety limit
  var itemCount = 0

  while p.peek().kind == tkDash:
    itemCount += 1
    if itemCount > maxItems:
      var err = newException(ParseError, "List exceeded maximum items - possible infinite loop")
      err.line = p.peek().line
      err.col = p.peek().col
      raise err
    discard p.advance() # Skip -
    p.skipNewlines()
    result.add(p.parseString())
    p.skipNewlines()

proc parseVariableDeclaration(p: var Parser): AstNode =
  ## Parse a variable declaration (name: value or name:\n  - item)
  let nameToken = p.expect(tkIdentifier)
  let name = nameToken.value

  var op = opSet
  let opTok = p.peek()
  if opTok.kind == tkColon:
    discard p.advance()
  elif opTok.kind == tkPlusColon:
    op = opAppend
    discard p.advance()
  elif opTok.kind == tkMinusColon:
    op = opRemove
    discard p.advance()
  else:
    var err = newException(ParseError, "Expected :, +: or -: but got " & $opTok.kind)
    err.line = opTok.line
    err.col = opTok.col
    raise err

  p.skipNewlines()

  # Check if it's a list or single value
  if p.peek().kind == tkDash:
    # List variable
    let items = p.parseListItems()
    return newListVariableNode(name, items, op, nameToken.line)
  else:
    # Single value variable
    let value = p.parseString()
    return newVariableNode(name, value, op, nameToken.line)

proc parseVarManipulation(p: var Parser, baseVar: string): AstNode =
  ## Parse variable manipulation: ${var.method().method()[index]}
  var methods: seq[VarManipMethod] = @[]
  var indexExpr = ""

  # Parse method chain
  while p.peek().kind == tkDot:
    discard p.advance() # Skip .
    let methodName = p.expect(tkIdentifier).value

    # Check for arguments
    var args: seq[string] = @[]
    if p.peek().kind == tkLParen:
      discard p.advance() # Skip (
      while p.peek().kind != tkRParen and p.peek().kind != tkEof:
        args.add(p.parseString())
        if p.peek().kind == tkComma:
          discard p.advance()
      discard p.expect(tkRParen)

    methods.add(VarManipMethod(name: methodName, args: args))

  # Check for indexing
  if p.peek().kind == tkLBracket:
    discard p.advance() # Skip [
        # Read everything until ]
    var indexParts: seq[string] = @[]
    while p.peek().kind != tkRBracket and p.peek().kind != tkEof:
      let tok = p.advance()
      indexParts.add(tok.value)
    discard p.expect(tkRBracket)
    indexExpr = indexParts.join("")

  return newVarManipNode(baseVar, methods, indexExpr)

proc parseExpression(p: var Parser): string =
  ## Parse an expression (for conditions, arguments, etc.)
  ## Handles variable references and basic expressions
  var parts: seq[string] = @[]
  const maxIterations = 10000 # Safety limit
  var iterations = 0

  while true:
    iterations += 1
    if iterations > maxIterations:
      var err = newException(ParseError, "Expression parsing exceeded maximum iterations - possible infinite loop")
      err.line = p.peek().line
      err.col = p.peek().col
      raise err

    let tok = p.peek()
    case tok.kind
    of tkIdentifier, tkNumber:
      parts.add(tok.value)
      discard p.advance()
    of tkDollar:
      discard p.advance()
      if p.peek().kind == tkLBrace:
        discard p.advance() # Skip {

        var baseExpr = ""
        # Check for exec command
        if p.peek().kind == tkExec:
          discard p.advance()
          baseExpr = "exec"
          if p.peek().kind == tkLParen:
            baseExpr.add("(")
            discard p.advance()
            baseExpr.add("\"" & p.parseString() & "\"")
            discard p.expect(tkRParen)
            baseExpr.add(")")
        else:
          let varName = p.expect(tkIdentifier).value
          baseExpr = varName

        # Check for manipulation
        if p.peek().kind == tkDot or p.peek().kind == tkLBracket:
          # Store as valid variable expression
          parts.add("${" & baseExpr)
          var manipIterations = 0
          while p.peek().kind != tkRBrace and p.peek().kind != tkEof:
            manipIterations += 1
            if manipIterations > maxIterations:
              var err = newException(ParseError, "Variable manipulation parsing exceeded maximum iterations")
              err.line = p.peek().line
              err.col = p.peek().col
              raise err
            parts.add(p.advance().value)
        else:
          parts.add("${" & baseExpr)
        discard p.expect(tkRBrace)
        parts.add("}")
      else:
        let varName = p.expect(tkIdentifier).value
        parts.add("$" & varName)
    of tkString:
      parts.add("\"" & tok.value & "\"")
      discard p.advance()
    of tkRegexString:
      # Regex string e"pattern" - preserve with special marker
      parts.add("e\"" & tok.value & "\"")
      discard p.advance()
    of tkEquals, tkLBrace, tkRBrace:
      # Stop at these delimiters
      break
    of tkNotEquals:
      # Include != operator in expression
      parts.add(tok.value)
      discard p.advance()
    of tkDoubleEquals:
      # Include == operator in expression
      parts.add(tok.value)
      discard p.advance()
    of tkRegexMatch:
      # Include =~ operator in expression
      parts.add(tok.value)
      discard p.advance()
    of tkOr:
      # Include || operator in expression
      parts.add(tok.value)
      discard p.advance()
    of tkAnd:
      # Include && operator in expression
      parts.add(tok.value)
      discard p.advance()
    of tkDot, tkLParen, tkRParen:
      # Allow method chaining and function calls in expressions
      parts.add(tok.value)
      discard p.advance()
    else:
      break

  return parts.join(" ").strip()

proc parseCondition(p: var Parser): string =
  ## Parse a condition expression for if statements
  ## Handles ||, &&, ==, !=, =~, and regex strings e"pattern"
  var parts: seq[string] = @[]
  const maxIterations = 10000
  var iterations = 0

  while true:
    iterations += 1
    if iterations > maxIterations:
      var err = newException(ParseError, "Condition parsing exceeded maximum iterations")
      err.line = p.peek().line
      err.col = p.peek().col
      raise err

    let tok = p.peek()
    case tok.kind
    of tkIdentifier, tkNumber:
      parts.add(tok.value)
      discard p.advance()
    of tkDollar:
      discard p.advance()
      if p.peek().kind == tkLBrace:
        discard p.advance() # Skip {
        var baseExpr = ""
        if p.peek().kind == tkExec:
          discard p.advance()
          baseExpr = "exec"
          if p.peek().kind == tkLParen:
            baseExpr.add("(")
            discard p.advance()
            baseExpr.add("\"" & p.parseString() & "\"")
            discard p.expect(tkRParen)
            baseExpr.add(")")
        else:
          let varName = p.expect(tkIdentifier).value
          baseExpr = varName

        if p.peek().kind == tkDot or p.peek().kind == tkLBracket:
          parts.add("${" & baseExpr)
          var manipIterations = 0
          while p.peek().kind != tkRBrace and p.peek().kind != tkEof:
            manipIterations += 1
            if manipIterations > maxIterations:
              var err = newException(ParseError, "Variable manipulation parsing exceeded maximum iterations")
              err.line = p.peek().line
              err.col = p.peek().col
              raise err
            parts.add(p.advance().value)
        else:
          parts.add("${" & baseExpr)
        discard p.expect(tkRBrace)
        parts.add("}")
      else:
        let varName = p.expect(tkIdentifier).value
        parts.add("$" & varName)
    of tkString:
      parts.add("\"" & tok.value & "\"")
      discard p.advance()
    of tkRegexString:
      # Regex string e"pattern"
      parts.add("e\"" & tok.value & "\"")
      discard p.advance()
    of tkDoubleEquals:
      parts.add("==")
      discard p.advance()
    of tkNotEquals:
      parts.add("!=")
      discard p.advance()
    of tkRegexMatch:
      parts.add("=~")
      discard p.advance()
    of tkOr:
      parts.add("||")
      discard p.advance()
    of tkAnd:
      parts.add("&&")
      discard p.advance()
    of tkLBrace, tkRBrace, tkNewline, tkEof:
      # End of condition
      break
    of tkDot, tkLParen, tkRParen:
      parts.add(tok.value)
      discard p.advance()
    else:
      break

  return parts.join(" ").strip()

proc parseMacroArgValue(p: var Parser): string =
  ## Parse a macro argument value after =
  ## Handles paths like /usr/share/man, variables like $var, and quoted strings
  ## Reads until whitespace, newline, or next -- flag
  var parts: seq[string] = @[]
  const maxIterations = 10000
  var iterations = 0

  while p.peek().kind notin {tkNewline, tkRBrace, tkEof}:
    iterations += 1
    if iterations > maxIterations:
      var err = newException(ParseError, "Macro argument value parsing exceeded maximum iterations")
      err.line = p.peek().line
      err.col = p.peek().col
      raise err

    let tok = p.peek()

    # Stop if we hit the next --flag
    if tok.kind == tkDash and p.peek(1).kind == tkDash:
      break

    # Handle different token types
    case tok.kind
    of tkString:
      parts.add(tok.value)
      discard p.advance()
    of tkIdentifier, tkNumber:
      parts.add(tok.value)
      discard p.advance()
    of tkDollar:
      # Variable reference
      discard p.advance()
      if p.peek().kind == tkLBrace:
        discard p.advance() # Skip {
        var varExpr = "${"
        var braceDepth = 1
        while braceDepth > 0 and p.peek().kind != tkEof:
          if p.peek().kind == tkLBrace:
            braceDepth += 1
          elif p.peek().kind == tkRBrace:
            braceDepth -= 1
            if braceDepth == 0:
              discard p.advance()
              break
          varExpr.add(p.advance().value)
        varExpr.add("}")
        parts.add(varExpr)
      else:
        let varName = p.expect(tkIdentifier).value
        parts.add("$" & varName)
    of tkDash:
      # Single dash (not --), include it
      parts.add(tok.value)
      discard p.advance()
    of tkDot, tkColon, tkEquals:
      # Path separators and special chars
      parts.add(tok.value)
      discard p.advance()
    else:
      # Any other token, include its value
      parts.add(tok.value)
      discard p.advance()

  return parts.join("")

proc parseMacroFlagName(p: var Parser): string =
  ## Parse a macro flag name after --
  ## Flag names can contain dashes, e.g., enable-pc-files, with-pkg-config-libdir
  ## Reads identifiers and dashes until = or end of flag
  var parts: seq[string] = @[]

  while p.peek().kind in {tkIdentifier, tkDash}:
    let tok = p.peek()
    # Stop if this dash is part of -- (next flag)
    if tok.kind == tkDash and p.peek(1).kind == tkDash:
      break
    parts.add(tok.value)
    discard p.advance()

  return parts.join("")

proc parseSingleTokenOrVar(p: var Parser): string =
  ## Parse a single token (string/identifier) or variable reference
  let tok = p.peek()
  case tok.kind
  of tkString, tkIdentifier, tkNumber:
    discard p.advance()
    return tok.value
  of tkDollar:
    discard p.advance()
    if p.peek().kind == tkLBrace:
      discard p.advance() # Skip {

      var baseExpr = ""
      if p.peek().kind == tkExec:
        discard p.advance()
        baseExpr = "exec"
        if p.peek().kind == tkLParen:
          baseExpr.add("(")
          discard p.advance()
          baseExpr.add("\"" & p.parseString() & "\"")
          discard p.expect(tkRParen)
          baseExpr.add(")")
      else:
        baseExpr = p.expect(tkIdentifier).value

      # Check for manipulation
      var res = "${" & baseExpr
      if p.peek().kind == tkDot or p.peek().kind == tkLBracket:
        const maxIterations = 10000
        var iterations = 0
        while p.peek().kind != tkRBrace and p.peek().kind != tkEof:
          iterations += 1
          if iterations > maxIterations:
            var err = newException(ParseError, "Variable manipulation exceeded maximum iterations")
            err.line = p.peek().line
            err.col = p.peek().col
            raise err
          res.add(p.advance().value)
      discard p.expect(tkRBrace)
      res.add("}")
      return res
    else:
      let varName = p.expect(tkIdentifier).value
      return "$" & varName
  else:
    var err = newException(ParseError, "Expected string, identifier or variable, got " &
        $tok.kind & " '" & tok.value & "'")
    err.line = tok.line
    err.col = tok.col
    raise err

proc parseStatement(p: var Parser): AstNode =
  ## Parse a single statement inside a function
  p.skipCommentsAndNewlines()
  let tok = p.peek()

  case tok.kind
  of tkExec:
    discard p.advance()
    let cmd = p.parseExpression()
    return newExecNode(cmd, tok.line)

  of tkMacro:
    discard p.advance()
    let macroName = p.expect(tkIdentifier).value
    var args: seq[string] = @[]

    # Parse macro arguments until newline or }
    # Supports: positional args, variable refs (${var}), -flag and --flag style args
    const maxArgs = 1000
    var argCount = 0
    while p.peek().kind notin {tkNewline, tkRBrace, tkEof}:
      argCount += 1
      if argCount > maxArgs:
        var err = newException(ParseError, "Macro exceeded maximum arguments")
        err.line = p.peek().line
        err.col = p.peek().col
        raise err

      let currentTok = p.peek()

      # Handle --flag and --flag=value style arguments
      if currentTok.kind == tkDash and p.peek(1).kind == tkDash:
        discard p.advance() # First -
        discard p.advance() # Second -
        let argName = p.parseMacroFlagName()
        var argValue = argName
        if p.peek().kind == tkEquals:
          discard p.advance()
          argValue = argName & "=" & p.parseMacroArgValue()
        args.add("--" & argValue)
      # Handle -flag and -flag=value or -flagVALUE style arguments (single dash)
      elif currentTok.kind == tkDash:
        discard p.advance() # Single -
        # Read the flag and any attached value (like -j4 or -O2)
        let flagArg = p.parseMacroArgValue()
        args.add("-" & flagArg)
      # Handle variable references and other expressions
      elif currentTok.kind in {tkDollar, tkString, tkIdentifier, tkNumber}:
        args.add(p.parseSingleTokenOrVar())
      else:
        # Unknown token type in macro args - skip it to avoid infinite loop
        var err = newException(ParseError,
            "Unexpected token in macro arguments: " & $currentTok.kind & " '" &
            currentTok.value & "'")
        err.line = currentTok.line
        err.col = currentTok.col
        raise err

    return newMacroNode(macroName, args, tok.line)

  of tkPrint, tkEcho:
    discard p.advance()
    let text = p.parseExpression()
    return newPrintNode(text, tok.line)

  of tkCd:
    discard p.advance()
    let path = p.parseExpression()
    return newCdNode(path, tok.line)

  of tkEnv:
    discard p.advance()
    let varName = p.expect(tkIdentifier).value
    discard p.expect(tkEquals)
    let value = p.parseExpression()
    return newEnvNode(varName, value, tok.line)

  of tkLocal:
    discard p.advance()
    let varName = p.expect(tkIdentifier).value
    discard p.expect(tkEquals)
    let value = p.parseExpression()
    return newLocalNode(varName, value, tok.line)

  of tkGlobal:
    discard p.advance()
    let varName = p.expect(tkIdentifier).value
    discard p.expect(tkEquals)
    let value = p.parseExpression()
    return newGlobalNode(varName, value, tok.line)

  of tkWrite:
    discard p.advance()
    let path = p.parseSingleTokenOrVar()
    let content = p.parseExpression()
    return newWriteNode(path, content, tok.line)

  of tkAppend:
    discard p.advance()
    let path = p.parseSingleTokenOrVar()
    let content = p.parseExpression()
    return newAppendNode(path, content, tok.line)

  of tkIf:
    discard p.advance()
    let condition = p.parseCondition()
    discard p.expect(tkLBrace)
    p.skipNewlines()

    var thenBranch: seq[AstNode] = @[]
    const maxStatements = 10000 # Safety limit
    var stmtCount = 0
    while p.peek().kind != tkRBrace and p.peek().kind != tkEof:
      stmtCount += 1
      if stmtCount > maxStatements:
        var err = newException(ParseError, "If body exceeded maximum statements - possible infinite loop")
        err.line = p.peek().line
        err.col = p.peek().col
        raise err
      thenBranch.add(p.parseStatement())
      p.skipCommentsAndNewlines()
    discard p.expect(tkRBrace)

    var elseBranch: seq[AstNode] = @[]
    p.skipNewlines()
    if p.peek().kind == tkElse:
      discard p.advance()
      discard p.expect(tkLBrace)
      p.skipNewlines()
      stmtCount = 0
      while p.peek().kind != tkRBrace and p.peek().kind != tkEof:
        stmtCount += 1
        if stmtCount > maxStatements:
          var err = newException(ParseError, "Else body exceeded maximum statements - possible infinite loop")
          err.line = p.peek().line
          err.col = p.peek().col
          raise err
        elseBranch.add(p.parseStatement())
        p.skipCommentsAndNewlines()
      discard p.expect(tkRBrace)

    return newIfNode(condition, thenBranch, elseBranch, tok.line)

  of tkFor:
    discard p.advance()
    let iterVar = p.expect(tkIdentifier).value
    discard p.expect(tkIn)

    # Check if it's an inline list literal, variable expression, or variable name
    var listVar = ""
    var listLiteral: seq[string] = @[]

    if p.peek().kind == tkLBracket:
      # Inline list literal: ["item1", "item2", ...]
      discard p.advance() # Skip [
      p.skipNewlines()
      while p.peek().kind != tkRBracket and p.peek().kind != tkEof:
        listLiteral.add(p.parseString())
        p.skipNewlines()
        if p.peek().kind == tkComma:
          discard p.advance() # Skip comma
          p.skipNewlines()
      discard p.expect(tkRBracket)
    elif p.peek().kind == tkDollar or p.peek().kind == tkString:
      # Variable expression: ${expr} or "$expr" - store as listVar for runtime resolution
      listVar = p.parseSingleTokenOrVar()
    else:
      # Plain variable name
      listVar = p.expect(tkIdentifier).value

    discard p.expect(tkLBrace)
    p.skipNewlines()

    var body: seq[AstNode] = @[]
    const maxForStatements = 10000 # Safety limit
    var forStmtCount = 0
    while p.peek().kind != tkRBrace and p.peek().kind != tkEof:
      forStmtCount += 1
      if forStmtCount > maxForStatements:
        var err = newException(ParseError, "For body exceeded maximum statements - possible infinite loop")
        err.line = p.peek().line
        err.col = p.peek().col
        raise err
      body.add(p.parseStatement())
      p.skipCommentsAndNewlines()
    discard p.expect(tkRBrace)

    return newForNode(iterVar, listVar, body, tok.line, listLiteral)

  of tkContinue:
    discard p.advance()
    return newContinueNode(tok.line)

  of tkBreak:
    discard p.advance()
    return newBreakNode(tok.line)

  of tkIdentifier:
    # Could be a custom function call
    let name = p.advance().value
    var args: seq[string] = @[]
    # Parse arguments until newline or }
    const maxArgs = 1000 # Safety limit
    var argCount = 0
    while p.peek().kind notin {tkNewline, tkRBrace, tkEof}:
      argCount += 1
      if argCount > maxArgs:
        var err = newException(ParseError,
            "Function call exceeded maximum arguments - possible parse error at token: " &
            $p.peek().kind)
        err.line = p.peek().line
        err.col = p.peek().col
        raise err
      let startPos = p.pos
      let expr = p.parseExpression()
      # If parseExpression didn't consume anything and returned empty, we're stuck
      if p.pos == startPos and expr.len == 0:
        var err = newException(ParseError,
            "Unexpected token in function call arguments: " & $p.peek().kind &
            " '" & p.peek().value & "'")
        err.line = p.peek().line
        err.col = p.peek().col
        raise err
      if expr.len > 0:
        args.add(expr)
      if p.peek().kind == tkNewline or p.peek().kind == tkRBrace:
        break
    return newFuncCallNode(name, args, tok.line)

  else:
    # Unknown token - report error with location
    var err = newException(ParseError, "Unexpected token at start of statement: " &
        $tok.kind & " '" & tok.value & "'")
    err.line = tok.line
    err.col = tok.col
    raise err

proc parseFunctionBody(p: var Parser): seq[AstNode] =
  ## Parse a function body (statements between { })
  result = @[]
  discard p.expect(tkLBrace)
  p.skipNewlines()

  const maxStatements = 10000 # Safety limit
  var stmtCount = 0

  while p.peek().kind != tkRBrace and p.peek().kind != tkEof:
    stmtCount += 1
    if stmtCount > maxStatements:
      var err = newException(ParseError, "Function body exceeded maximum statements - possible infinite loop")
      err.line = p.peek().line
      err.col = p.peek().col
      raise err
    result.add(p.parseStatement())
    p.skipCommentsAndNewlines()

  discard p.expect(tkRBrace)

proc parseFunction(p: var Parser, isCustom: bool = false): AstNode =
  ## Parse a function definition
  let tok = p.peek()

  if isCustom:
    discard p.expect(tkFunc)

  let funcName = p.expect(tkIdentifier).value
  let body = p.parseFunctionBody()

  if isCustom:
    return newCustomFuncNode(funcName, body, tok.line)
  else:
    return newFunctionNode(funcName, body, tok.line)

proc parse*(p: var Parser): ParsedRunfile =
  ## Parse a complete run3 file
  result.variables = @[]
  result.functions = @[]
  result.customFuncs = @[]

  const maxIterations = 100000 # Safety limit
  var iterations = 0

  debug "parse: starting variable declarations"
  # Parse variable declarations (header)
  while p.peek().kind notin {tkEof, tkFunc} and
              p.peek().kind != tkIdentifier or
              (p.peek().kind == tkIdentifier and p.peek(1).kind in {tkColon,
                      tkPlusColon, tkMinusColon}):
      iterations += 1
      if iterations > maxIterations:
        raise newException(ParseError, "Parser exceeded maximum iterations - possible infinite loop")

      p.skipCommentsAndNewlines()

      if p.peek().kind == tkIdentifier and p.peek(1).kind in {tkColon,
              tkPlusColon, tkMinusColon}:
        result.variables.add(p.parseVariableDeclaration())
        p.skipNewlines()
      elif p.peek().kind in {tkFunc, tkIdentifier}:
        break
      elif p.peek().kind == tkEof:
        break
      else:
        discard p.advance()

  debug "parse: finished variable declarations, parsed "&(
      $result.variables.len)&" variables"
  # Parse functions
  p.skipCommentsAndNewlines()
  debug "parse: starting function parsing"
  while p.peek().kind != tkEof:
    iterations += 1
    if iterations > maxIterations:
      raise newException(ParseError, "Parser exceeded maximum iterations - possible infinite loop")

    debug "parse: function loop iteration "&($iterations)&", token kind: "&(
        $p.peek().kind)
    if p.peek().kind == tkFunc:
      debug "parse: parsing custom function"
      result.customFuncs.add(p.parseFunction(isCustom = true))
    elif p.peek().kind == tkIdentifier and p.peek(1).kind == tkLBrace:
      debug "parse: parsing function '"&p.peek().value&"'"
      result.functions.add(p.parseFunction(isCustom = false))
    else:
      discard p.advance()
    p.skipCommentsAndNewlines()

  debug "parse: completed, "&($result.functions.len)&" functions, "&(
      $result.customFuncs.len)&" custom functions"

proc parseRun3File*(path: string): ParsedRunfile =
  ## Parse a run3 file from disk
  debug "parseRun3File: reading file '"&path&"'"
  let content = readFile(path)
  debug "parseRun3File: file read, size: "&($content.len)&" bytes"
  debug "parseRun3File: tokenizing"
  let tokens = tokenize(content)
  debug "parseRun3File: tokenized, "&($tokens.len)&" tokens"
  var parser = initParser(tokens)
  debug "parseRun3File: parsing"
  result = parser.parse()
  debug "parseRun3File: parsing completed"
