## Parser for Kongue scripting language
## Converts tokens into an AST

import strutils
import ast
import lexer
import utils

when not declared(readFile):
  import os

proc escapeStringForOutput(s: string): string =
  ## Escape special characters in a string for output
  ## Preserves existing escapes inside ${} expressions
  result = ""
  var i = 0
  while i < s.len:
    let c = s[i]
    if c == '$' and i + 1 < s.len and s[i + 1] == '{':
      # Inside ${} expression - copy everything until matching }
      # These already have escapes preserved by the lexer
      var braceDepth = 0
      while i < s.len:
        if s[i] == '{':
          braceDepth += 1
        elif s[i] == '}':
          braceDepth -= 1
          if braceDepth == 0:
            result.add(s[i])
            i += 1
            break
        result.add(s[i])
        i += 1
    else:
      # Outside ${} - need to escape special chars
      case c
      of '\n': result.add("\\n")
      of '\t': result.add("\\t")
      of '\r': result.add("\\r")
      of '\\': result.add("\\\\")
      of '"': result.add("\\\"")
      else: result.add(c)
      i += 1

type
  Parser* = object
    ## Parser state
    tokens*: seq[Token]
    pos*: int

  ParseError* = object of CatchableError
    ## Parse error with line information
    line*: int
    col*: int

proc raiseParseError(msg: string, line, col: int) {.noreturn.} =
  ## Raise a ParseError with line and column information
  var err = newException(ParseError, msg)
  err.line = line
  err.col = col
  raise err

proc initParser*(tokens: seq[Token]): Parser =
  ## Initialize a new parser
  result.tokens = tokens
  result.pos = 0

proc peek*(p: Parser, offset: int = 0): Token =
  ## Peek at a token without consuming it
  let pos = p.pos + offset
  if pos >= p.tokens.len:
    return Token(kind: tkEof, value: "", line: 0, col: 0)
  return p.tokens[pos]

proc advance*(p: var Parser): Token =
  ## Consume and return the current token
  if p.pos >= p.tokens.len:
    return Token(kind: tkEof, value: "", line: 0, col: 0)
  result = p.tokens[p.pos]
  p.pos += 1

proc expect(p: var Parser, kind: TokenKind): Token =
  ## Expect a specific token kind, raise error if not found
  let tok = p.advance()
  if tok.kind != kind:
    raiseParseError("Expected " & $kind & " but got " & $tok.kind, tok.line, tok.col)
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
    raiseParseError("Expected string but got " & $tok.kind, tok.line, tok.col)

proc parseStringValue(p: var Parser): string =
  ## Parse a string value, concatenating multiple unquoted tokens
  ## This handles cases where unquoted values like hex checksums
  ## are split into multiple tokens by the lexer
  var parts: seq[string] = @[]

  while true:
    let tok = p.peek()
    case tok.kind
    of tkString:
      parts.add(tok.value)
      discard p.advance()
      break # Quoted strings are complete
    of tkIdentifier, tkNumber:
      parts.add(tok.value)
      discard p.advance()
      # Check if next token should be part of this value
      let nextTok = p.peek()
      if nextTok.kind notin {tkIdentifier, tkNumber}:
        break
    else:
      break

  return parts.join("")

proc parseListItems(p: var Parser): seq[string] =
  ## Parse list items (lines starting with -)
  result = @[]
  p.skipNewlines()

  var itemCount = 0

  while p.peek().kind == tkDash:
    itemCount += 1
    if itemCount > maxItems:
      raiseParseError("List exceeded maximum items - possible infinite loop",
          p.peek().line, p.peek().col)
    discard p.advance() # Skip -
    p.skipNewlines()
    result.add(p.parseStringValue())
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
    raiseParseError("Expected :, +: or -: but got " & $opTok.kind, opTok.line, opTok.col)

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

proc parseExecCommand(p: var Parser): string =
  ## Parse an exec command - returns raw string value without re-quoting
  ## This preserves the original quoting for shell commands
  let tok = p.peek()
  if tok.kind == tkString:
    discard p.advance()
    return tok.value
  elif tok.kind == tkIdentifier or tok.kind == tkNumber:
    discard p.advance()
    return tok.value
  else:
    raiseParseError("Expected string for exec command but got " & $tok.kind,
        tok.line, tok.col)

proc parseExpression(p: var Parser): string =
  ## Parse an expression (for conditions, arguments, etc.)
  ## Handles variable references and basic expressions
  var parts: seq[string] = @[]
  var iterations = 0

  while true:
    iterations += 1
    if iterations > maxIterations:
      raiseParseError("Expression parsing exceeded maximum iterations - possible infinite loop",
          p.peek().line, p.peek().col)

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
              raiseParseError("Variable manipulation parsing exceeded maximum iterations",
                  p.peek().line, p.peek().col)
            parts.add(p.advance().value)
        else:
          parts.add("${" & baseExpr)
        discard p.expect(tkRBrace)
        parts.add("}")
      else:
        let varName = p.expect(tkIdentifier).value
        parts.add("$" & varName)
    of tkString:
      parts.add("\"" & escapeStringForOutput(tok.value) & "\"")
      discard p.advance()
    of tkRegexString:
      # Regex string e"pattern" - preserve with special marker
      parts.add("e\"" & escapeStringForOutput(tok.value) & "\"")
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
  var iterations = 0

  while true:
    iterations += 1
    if iterations > maxIterations:
      raiseParseError("Condition parsing exceeded maximum iterations",
          p.peek().line, p.peek().col)

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
              raiseParseError("Variable manipulation parsing exceeded maximum iterations",
                  p.peek().line, p.peek().col)
            parts.add(p.advance().value)
        else:
          parts.add("${" & baseExpr)
        discard p.expect(tkRBrace)
        parts.add("}")
      else:
        let varName = p.expect(tkIdentifier).value
        parts.add("$" & varName)
    of tkString:
      parts.add("\"" & escapeStringForOutput(tok.value) & "\"")
      discard p.advance()
    of tkRegexString:
      # Regex string e"pattern"
      parts.add("e\"" & escapeStringForOutput(tok.value) & "\"")
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
  var iterations = 0

  while p.peek().kind notin {tkNewline, tkRBrace, tkEof}:
    iterations += 1
    if iterations > maxIterations:
      raiseParseError("Macro argument value parsing exceeded maximum iterations",
          p.peek().line, p.peek().col)

    let tok = p.peek()

    # Stop if we hit the next --flag or -flag (single dash followed by identifier)
    if tok.kind == tkDash:
      let next = p.peek(1)
      if next.kind == tkDash or next.kind == tkIdentifier:
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
  ## The lexer already handles dash-containing identifiers like enable-pc-files
  ## So we just need to read a single identifier token
  if p.peek().kind == tkIdentifier:
    return p.advance().value
  else:
    return ""

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
        var iterations = 0
        while p.peek().kind != tkRBrace and p.peek().kind != tkEof:
          iterations += 1
          if iterations > maxIterations:
            raiseParseError("Variable manipulation exceeded maximum iterations",
                p.peek().line, p.peek().col)
          res.add(p.advance().value)
      discard p.expect(tkRBrace)
      res.add("}")
      return res
    else:
      let varName = p.expect(tkIdentifier).value
      return "$" & varName
  else:
    raiseParseError("Expected string, identifier or variable, got " &
        $tok.kind & " '" & tok.value & "'", tok.line, tok.col)

# Forward declaration for mutual recursion
proc parseStatement*(p: var Parser): AstNode

proc parseStatementBlock(p: var Parser, blockName: string): seq[AstNode] =
  ## Parse a block of statements until }
  ## Used by if, for, and function body parsing
  result = @[]
  var stmtCount = 0
  while p.peek().kind != tkRBrace and p.peek().kind != tkEof:
    stmtCount += 1
    if stmtCount > maxStatements:
      raiseParseError(blockName & " exceeded maximum statements - possible infinite loop",
          p.peek().line, p.peek().col)
    result.add(p.parseStatement())
    p.skipCommentsAndNewlines()

proc parseMacroStatement(p: var Parser, line: int): AstNode =
  ## Parse a macro statement: macro name --flag1 --flag2=value arg1
  let macroName = p.expect(tkIdentifier).value
  var args: seq[string] = @[]

  # Parse macro arguments until newline or }
  # Supports: positional args, variable refs (${var}), -flag and --flag style args
  var argCount = 0
  while p.peek().kind notin {tkNewline, tkRBrace, tkEof}:
    argCount += 1
    if argCount > maxArgs:
      raiseParseError("Macro exceeded maximum arguments", p.peek().line, p.peek().col)

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
    # Handle variable references and other expressions (including compound args like install.prefix=/usr)
    elif currentTok.kind in {tkDollar, tkString, tkIdentifier, tkNumber}:
      # Use parseMacroArgValue to handle compound expressions with dots, equals, etc.
      args.add(p.parseMacroArgValue())
    # Handle dots at start of path (like ../foo or ./bar)
    elif currentTok.kind == tkDot:
      args.add(p.parseMacroArgValue())
    else:
      # Unknown token type in macro args - skip it to avoid infinite loop
      raiseParseError("Unexpected token in macro arguments: " &
          $currentTok.kind & " '" & currentTok.value & "'",

currentTok.line, currentTok.col)

  return newMacroNode(macroName, args, line)

proc parseIfStatement(p: var Parser, line: int): AstNode =
  ## Parse an if statement: if condition { } else { }
  let condition = p.parseCondition()
  discard p.expect(tkLBrace)
  p.skipNewlines()

  let thenBranch = p.parseStatementBlock("If body")
  discard p.expect(tkRBrace)

  var elseBranch: seq[AstNode] = @[]
  p.skipNewlines()
  if p.peek().kind == tkElse:
    discard p.advance()
    discard p.expect(tkLBrace)
    p.skipNewlines()
    elseBranch = p.parseStatementBlock("Else body")
    discard p.expect(tkRBrace)

  return newIfNode(condition, thenBranch, elseBranch, line)

proc parseForStatement(p: var Parser, line: int): AstNode =
  ## Parse a for loop: for var in list { }
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

  let body = p.parseStatementBlock("For body")
  discard p.expect(tkRBrace)

  return newForNode(iterVar, listVar, body, line, listLiteral)

proc parseFuncCallStatement(p: var Parser, name: string, line: int): AstNode =
  ## Parse a function call: funcname arg1 arg2
  var args: seq[string] = @[]
  var argCount = 0
  while p.peek().kind notin {tkNewline, tkRBrace, tkEof}:
    argCount += 1
    if argCount > maxArgs:
      raiseParseError("Function call exceeded maximum arguments - possible parse error at token: " &
          $p.peek().kind, p.peek().line, p.peek().col)
    let startPos = p.pos
    let expr = p.parseExpression()
    # If parseExpression didn't consume anything and returned empty, we're stuck
    if p.pos == startPos and expr.len == 0:
      raiseParseError("Unexpected token in function call arguments: " & $p.peek(
        ).kind & " '" & p.peek().value & "'", p.peek().line, p.peek().col)
    if expr.len > 0:
      args.add(expr)
    if p.peek().kind == tkNewline or p.peek().kind == tkRBrace:
      break
  return newFuncCallNode(name, args, line)

proc parseStatement*(p: var Parser): AstNode =
  ## Parse a single statement inside a function
  p.skipCommentsAndNewlines()
  let tok = p.peek()

  case tok.kind
  of tkExec:
    discard p.advance()
    return newExecNode(p.parseExecCommand(), tok.line)

  of tkMacro:
    discard p.advance()
    return p.parseMacroStatement(tok.line)

  of tkPrint, tkEcho:
    discard p.advance()
    return newPrintNode(p.parseExpression(), tok.line)

  of tkCd:
    discard p.advance()
    return newCdNode(p.parseExpression(), tok.line)

  of tkEnv:
    discard p.advance()
    let varName = p.expect(tkIdentifier).value
    discard p.expect(tkEquals)
    return newEnvNode(varName, p.parseExpression(), tok.line)

  of tkLocal:
    discard p.advance()
    let varName = p.expect(tkIdentifier).value
    discard p.expect(tkEquals)
    return newLocalNode(varName, p.parseExpression(), tok.line)

  of tkGlobal:
    discard p.advance()
    let varName = p.expect(tkIdentifier).value
    discard p.expect(tkEquals)
    return newGlobalNode(varName, p.parseExpression(), tok.line)

  of tkWrite:
    discard p.advance()
    let path = p.parseSingleTokenOrVar()
    return newWriteNode(path, p.parseExpression(), tok.line)

  of tkAppend:
    discard p.advance()
    let path = p.parseSingleTokenOrVar()
    return newAppendNode(path, p.parseExpression(), tok.line)

  of tkIf:
    discard p.advance()
    return p.parseIfStatement(tok.line)

  of tkFor:
    discard p.advance()
    return p.parseForStatement(tok.line)

  of tkContinue:
    discard p.advance()
    return newContinueNode(tok.line)

  of tkBreak:
    discard p.advance()
    return newBreakNode(tok.line)

  of tkIdentifier:
    # Could be a custom function call
    let name = p.advance().value
    return p.parseFuncCallStatement(name, tok.line)

  else:
    # Unknown token - report error with location
    raiseParseError("Unexpected token at start of statement: " &
        $tok.kind & " '" & tok.value & "'", tok.line, tok.col)

proc parseFunctionBody(p: var Parser): seq[AstNode] =
  ## Parse a function body (statements between { })
  discard p.expect(tkLBrace)
  p.skipNewlines()
  result = p.parseStatementBlock("Function body")
  discard p.expect(tkRBrace)

proc parseFunction*(p: var Parser, isCustom: bool = false): AstNode =
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

proc parse*(p: var Parser): ParsedScript =
  ## Parse a complete Kongue script
  result.variables = @[]
  result.functions = @[]
  result.customFuncs = @[]

  var iterations = 0

  debug "parse: starting variable declarations"
  # Parse variable declarations (header)
  while p.peek().kind notin {tkEof, tkFunc} and
              p.peek().kind != tkIdentifier or
              (p.peek().kind == tkIdentifier and p.peek(1).kind in {tkColon,
                      tkPlusColon, tkMinusColon}):
      iterations += 1
      if iterations > maxTokens:
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
    if iterations > maxTokens:
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

proc parseFile*(path: string): ParsedScript =
  ## Parse a Kongue script file from disk
  debug "parseFile: reading file '"&path&"'"
  let content = readFile(path)
  debug "parseFile: file read, size: "&($content.len)&" bytes"
  debug "parseFile: tokenizing"
  let tokens = tokenize(content)
  debug "parseFile: tokenized, "&($tokens.len)&" tokens"
  var parser = initParser(tokens)
  debug "parseFile: parsing"
  result = parser.parse()
  debug "parseFile: parsing completed"
