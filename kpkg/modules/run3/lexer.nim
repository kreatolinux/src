## Lexer (Tokenizer) for run3 format
## Breaks input text into tokens for parsing

import strutils
import utils

type
  TokenKind* = enum
    ## Types of tokens
    tkEof,          # End of file
    tkNewline,      # Line break
    tkIdentifier,   # Variable/function name
    tkString,       # "quoted string"
    tkRegexString,  # e"regex pattern"
    tkNumber,       # Numeric literal
    tkColon,        # :
    tkPlusColon,    # +:
    tkMinusColon,   # -:
    tkDash,         # -
    tkLBrace,       # {
    tkRBrace,       # }
    tkLBracket,     # [
    tkRBracket,     # ]
    tkLParen,       # (
    tkRParen,       # )
    tkDot,          # .
    tkComma,        # ,
    tkEquals,       # =
    tkDollar,       # $
    tkBang,         # !
    tkNotEquals,    # !=
    tkDoubleEquals, # ==
    tkRegexMatch,   # =~
    tkOr,           # ||
    tkAnd,          # &&
    tkPipe,         # |
    tkComment,      # # comment
    tkFunc,         # func keyword
    tkIf,           # if keyword
    tkElse,         # else keyword
    tkFor,          # for keyword
    tkIn,           # in keyword
    tkExec,         # exec keyword
    tkMacro,        # macro keyword
    tkPrint,        # print keyword
    tkEcho,         # echo keyword
    tkCd,           # cd keyword
    tkEnv,          # env keyword
    tkLocal,        # local keyword
    tkGlobal,       # global keyword
    tkWrite,        # write keyword
    tkAppend,       # append keyword
    tkContinue,     # continue keyword
    tkBreak         # break keyword

  Token* = object
    ## A single token
    kind*: TokenKind
    value*: string
    line*: int
    col*: int

  Lexer* = object
    ## Lexer state
    input*: string
    pos*: int
    line*: int
    col*: int

proc initLexer*(input: string): Lexer =
  ## Initialize a new lexer
  result.input = input
  result.pos = 0
  result.line = 1
  result.col = 1

proc peek(lex: Lexer, offset: int = 0): char =
  ## Peek at a character without consuming it
  let pos = lex.pos + offset
  if pos >= lex.input.len:
    return '\0'
  return lex.input[pos]

proc advance(lex: var Lexer): char =
  ## Consume and return the current character
  if lex.pos >= lex.input.len:
    return '\0'

  result = lex.input[lex.pos]
  lex.pos += 1
  lex.col += 1

  if result == '\n':
    lex.line += 1
    lex.col = 1

proc skipWhitespace(lex: var Lexer, skipNewlines: bool = false) =
  ## Skip whitespace characters
  while true:
    let ch = lex.peek()
    if ch == ' ' or ch == '\t' or ch == '\r':
      discard lex.advance()
    elif skipNewlines and ch == '\n':
      discard lex.advance()
    else:
      break

proc readTripleString(lex: var Lexer): string =
  ## Read a triple-quoted string
  result = ""
  discard lex.advance() # 1st "
  discard lex.advance() # 2nd "
  discard lex.advance() # 3rd "

  # Skip immediate newline after opening triple quotes
  if lex.peek() == '\n':
    discard lex.advance()

  while true:
    let ch = lex.peek()
    if ch == '\0':
      break
    elif ch == '"' and lex.peek(1) == '"' and lex.peek(2) == '"':
      discard lex.advance()
      discard lex.advance()
      discard lex.advance()
      break
    else:
      result.add(lex.advance())

proc readString(lex: var Lexer, quote: char): string =
  ## Read a quoted string
  ## Handles nested quotes inside ${...} expressions
  result = ""
  discard lex.advance() # Skip opening quote
  var braceDepth = 0

  while true:
    if result.len > maxStringLen:
      raise newException(ValueError, "String exceeded maximum length - possible malformed input")
    let ch = lex.peek()
    if ch == '\0':
      break
    elif ch == '$' and lex.peek(1) == '{':
      # Start of variable expression - track brace depth
      result.add(lex.advance()) # $
      result.add(lex.advance()) # {
      braceDepth = 1
      # Read until matching closing brace
      while braceDepth > 0 and lex.peek() != '\0':
        if result.len > maxStringLen:
          raise newException(ValueError, "String exceeded maximum length - possible malformed input")
        let innerCh = lex.peek()
        if innerCh == '{':
          braceDepth += 1
          result.add(lex.advance())
        elif innerCh == '}':
          braceDepth -= 1
          result.add(lex.advance())
        elif innerCh == '"' or innerCh == '\'':
          # Nested string inside ${}, read it entirely (handling escapes)
          let innerQuote = innerCh
          result.add(lex.advance()) # Opening quote
          while lex.peek() != '\0':
            if result.len > maxStringLen:
              raise newException(ValueError, "String exceeded maximum length - possible malformed input")
            let strCh = lex.peek()
            if strCh == '\\' and lex.peek(1) != '\0':
              # Escape sequence - include both backslash and next char
              result.add(lex.advance()) # backslash
              result.add(lex.advance()) # escaped char
            elif strCh == innerQuote:
              result.add(lex.advance()) # Closing quote
              break
            else:
              result.add(lex.advance())
        elif innerCh == '\\' and lex.peek(1) != '\0':
          # Escape sequence outside of nested string - interpret it
          discard lex.advance() # Skip backslash
          let next = lex.advance()
          case next
          of 'n': result.add('\n')
          of 't': result.add('\t')
          of 'r': result.add('\r')
          of '\\': result.add('\\')
          of '"': result.add('"')
          of '\'': result.add('\'')
          else: result.add(next)
        else:
          result.add(lex.advance())
    elif ch == quote and braceDepth == 0:
      discard lex.advance()
      break
    elif ch == '\\':
      discard lex.advance()
      let next = lex.advance()
      case next
      of 'n': result.add('\n')
      of 't': result.add('\t')
      of 'r': result.add('\r')
      of '\\': result.add('\\')
      of '"': result.add('"')
      of '\'': result.add('\'')
      else: result.add(next)
    else:
      result.add(lex.advance())

proc readIdentifier(lex: var Lexer): string =
  ## Read an identifier (variable/function name)
  ## Note: identifiers can CONTAIN dashes but should not START with a dash
  result = ""
  var isFirst = true
  while true:
    let ch = lex.peek()
    if isFirst:
      # First character: must be alphanumeric or underscore (not dash)
      if ch.isAlphaAscii() or ch == '_':
        result.add(lex.advance())
        isFirst = false
      else:
        break
    else:
      # Subsequent characters: can include dash
      if ch.isAlphaNumeric() or ch == '_' or ch == '-':
        # Check if it's - followed by : (special case for variable operations)
        if ch == '-' and lex.peek(1) == ':':
          break
        result.add(lex.advance())
      else:
        break

proc readNumber(lex: var Lexer): string =
  ## Read a numeric literal
  result = ""
  while true:
    let ch = lex.peek()
    if ch.isDigit() or ch == '.':
      result.add(lex.advance())
    else:
      break

proc readComment(lex: var Lexer): string =
  ## Read a comment (from # to end of line)
  result = ""
  discard lex.advance() # Skip #
  while true:
    let ch = lex.peek()
    if ch == '\n' or ch == '\0':
      break
    result.add(lex.advance())

proc keywordOrIdentifier(value: string): TokenKind =
  ## Determine if an identifier is actually a keyword
  case value
  of "func": return tkFunc
  of "if": return tkIf
  of "else": return tkElse
  of "for": return tkFor
  of "in": return tkIn
  of "exec": return tkExec
  of "macro": return tkMacro
  of "print": return tkPrint
  of "echo": return tkEcho
  of "cd": return tkCd
  of "env": return tkEnv
  of "local": return tkLocal
  of "global": return tkGlobal
  of "write": return tkWrite
  of "append": return tkAppend
  of "continue": return tkContinue
  of "break": return tkBreak
  else: return tkIdentifier

proc nextToken*(lex: var Lexer): Token =
  ## Get the next token from the input
  lex.skipWhitespace(skipNewlines = false)

  result.line = lex.line
  result.col = lex.col

  let ch = lex.peek()

  case ch
  of '\0':
    result.kind = tkEof
    result.value = ""
  of '\n':
    result.kind = tkNewline
    result.value = "\n"
    discard lex.advance()
  of '#':
    result.kind = tkComment
    result.value = lex.readComment()
  of ':':
    result.kind = tkColon
    result.value = ":"
    discard lex.advance()
  of '+':
    if lex.peek(1) == ':':
      result.kind = tkPlusColon
      result.value = "+:"
      discard lex.advance()
      discard lex.advance()
    else:
      # Treat as identifier part or unknown
      result.value = "+"
      result.kind = tkIdentifier
      discard lex.advance()
  of '-':
    # Check if it's a list item, double dash, or standalone dash
    if lex.peek(1) == ':':
      result.kind = tkMinusColon
      result.value = "-:"
      discard lex.advance()
      discard lex.advance()
    elif lex.peek(1) == '-':
      # Double dash -- (for flags like --enable-foo)
      # Return single dash, next iteration will return the second dash
      result.kind = tkDash
      result.value = "-"
      discard lex.advance()
    else:
      # Single dash (list item marker or standalone)
      result.kind = tkDash
      result.value = "-"
      discard lex.advance()
  of '{':
    result.kind = tkLBrace
    result.value = "{"
    discard lex.advance()
  of '}':
    result.kind = tkRBrace
    result.value = "}"
    discard lex.advance()
  of '[':
    result.kind = tkLBracket
    result.value = "["
    discard lex.advance()
  of ']':
    result.kind = tkRBracket
    result.value = "]"
    discard lex.advance()
  of '(':
    result.kind = tkLParen
    result.value = "("
    discard lex.advance()
  of ')':
    result.kind = tkRParen
    result.value = ")"
    discard lex.advance()
  of '.':
    result.kind = tkDot
    result.value = "."
    discard lex.advance()
  of ',':
    result.kind = tkComma
    result.value = ","
    discard lex.advance()
  of '=':
    if lex.peek(1) == '=':
      result.kind = tkDoubleEquals
      result.value = "=="
      discard lex.advance()
      discard lex.advance()
    elif lex.peek(1) == '~':
      result.kind = tkRegexMatch
      result.value = "=~"
      discard lex.advance()
      discard lex.advance()
    else:
      result.kind = tkEquals
      result.value = "="
      discard lex.advance()
  of '!':
    if lex.peek(1) == '=':
      result.kind = tkNotEquals
      result.value = "!="
      discard lex.advance()
      discard lex.advance()
    else:
      result.kind = tkBang
      result.value = "!"
      discard lex.advance()
  of '|':
    if lex.peek(1) == '|':
      result.kind = tkOr
      result.value = "||"
      discard lex.advance()
      discard lex.advance()
    else:
      result.kind = tkPipe
      result.value = "|"
      discard lex.advance()
  of '&':
    if lex.peek(1) == '&':
      result.kind = tkAnd
      result.value = "&&"
      discard lex.advance()
      discard lex.advance()
    else:
      # Single & - treat as identifier character
      result.kind = tkIdentifier
      result.value = $lex.advance()
  of '$':
    result.kind = tkDollar
    result.value = "$"
    discard lex.advance()
  of '"':
    if lex.peek(1) == '"' and lex.peek(2) == '"':
      result.kind = tkString
      result.value = lex.readTripleString()
    else:
      result.kind = tkString
      result.value = lex.readString('"')
  of '\'':
    result.kind = tkString
    result.value = lex.readString('\'')
  else:
    if ch.isAlphaAscii() or ch == '_':
      # Check for e"..." regex string literal
      if ch == 'e' and lex.peek(1) == '"':
        discard lex.advance() # Skip 'e'
        result.kind = tkRegexString
        result.value = lex.readString('"')
      else:
        result.value = lex.readIdentifier()
        result.kind = keywordOrIdentifier(result.value)
    elif ch.isDigit():
      result.kind = tkNumber
      result.value = lex.readNumber()
    else:
      # Unknown character, skip it
      result.kind = tkIdentifier
      result.value = $lex.advance()

proc peekToken*(lex: var Lexer): Token =
  ## Peek at the next token without consuming it
  let savedPos = lex.pos
  let savedLine = lex.line
  let savedCol = lex.col
  result = lex.nextToken()
  lex.pos = savedPos
  lex.line = savedLine
  lex.col = savedCol

proc tokenize*(input: string): seq[Token] =
  ## Tokenize entire input into a sequence of tokens
  result = @[]
  var lex = initLexer(input)

  while true:
    if result.len > maxTokens:
      raise newException(ValueError, "Lexer exceeded maximum token count - file may be malformed")
    let tok = lex.nextToken()
    result.add(tok)
    if tok.kind == tkEof:
      break
