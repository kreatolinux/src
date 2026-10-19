## Strict, declarative Kongue manifest parser.
##
## Ordinary Kongue parsing remains intentionally permissive.  This module is
## an opt-in parser for manifests: its header is indentation-sensitive and
## recursively typed, and its function section is parsed with exact names.

import std/[strutils, sets]
import ast, lexer, parser

type
  ManifestParseError* = object of CatchableError
    line*: int
    col*: int

  SourceLine = object
    number, indent: int
    text: string

proc manifestError(msg: string, line: int, col = 1) {.noreturn.} =
  var e = newException(ManifestParseError, msg)
  e.line = line
  e.col = col
  raise e

proc stripComment(s: string): string =
  var quote = '\0'
  var escaped = false
  for i, c in s:
    if escaped:
      escaped = false
    elif c == '\\' and quote != '\0':
      escaped = true
    elif quote != '\0':
      if c == quote: quote = '\0'
    elif c in {'"', '\''}:
      quote = c
    elif c == '#':
      return s[0..<i].strip(leading = false)
  s

proc headerLine(raw: string, number: int): SourceLine =
  ## Tabs are rejected only in header indentation (kongue(5), manifest mode);
  ## function bodies keep ordinary Kongue whitespace rules.
  var indent = 0
  while indent < raw.len and raw[indent] in {' ', '\t'}:
    if raw[indent] == '\t':
      manifestError("tabs are not allowed in manifest indentation", number, indent + 1)
    inc indent
  SourceLine(number: number, indent: indent,
    text: stripComment(raw[indent..^1]).strip())

proc unescapeQuoted(s: string, line: int): string =
  if s.len < 2 or s[0] notin {'"', '\''} or s[^1] != s[0]:
    manifestError("manifest strings must be quoted", line)
  var i = 1
  while i < s.len - 1:
    if s[i] == '\\':
      inc i
      if i >= s.len - 1: manifestError("unterminated escape", line)
      case s[i]
      of 'n': result.add '\n'
      of 'r': result.add '\r'
      of 't': result.add '\t'
      of '\\': result.add '\\'
      of '"': result.add '"'
      of '\'': result.add '\''
      else: manifestError("unknown string escape", line)
    else:
      if s[i] == s[0]: manifestError("unexpected text after quoted string", line)
      result.add s[i]
    inc i

proc scalar(text: string, line: int): HeaderValue =
  if text.len == 0: manifestError("missing manifest value", line)
  if text[0] in {'"', '\''}:
    return HeaderValue(kind: hvString, line: line,
      stringVal: unescapeQuoted(text, line))
  if text == "true" or text == "false":
    return HeaderValue(kind: hvBool, line: line, boolVal: text == "true")
  if text.allCharsInSet({'0'..'9'}):
    try:
      return HeaderValue(kind: hvInt, line: line, intVal: parseBiggestInt(text))
    except ValueError:
      manifestError("integer is out of range", line)
  manifestError("unquoted manifest scalar must be true, false, or a non-negative integer", line)

proc splitPair(text: string, line: int): tuple[key, rest: string] =
  let colon = text.find(':')
  if colon <= 0: manifestError("expected key: value", line)
  result.key = text[0..<colon].strip()
  result.rest = text[colon + 1..^1].strip()
  if result.key.len == 0 or not result.key[0].isAlphaAscii():
    manifestError("invalid manifest key", line)
  for c in result.key:
    if not (c.isAlphaNumeric or c == '_'):
      manifestError("invalid manifest key", line)

proc parseBlock(lines: seq[SourceLine], pos: var int, indent: int): HeaderValue

proc emptyBlock(line: int): HeaderValue =
  ## `key:` with no nested block. The application decides whether the empty
  ## value is an empty sequence or an empty mapping.
  HeaderValue(kind: hvList, line: line, emptyBlock: true)

proc parseMap(lines: seq[SourceLine], pos: var int, indent: int): HeaderValue =
  result = HeaderValue(kind: hvMap, line: lines[pos].number)
  var keys = initHashSet[string]()
  while pos < lines.len and lines[pos].indent == indent and
      not lines[pos].text.startsWith("- "):
    let ln = lines[pos]
    let (key, rest) = splitPair(ln.text, ln.number)
    if key in keys: manifestError("duplicate manifest key '" & key & "'", ln.number)
    keys.incl(key)
    inc pos
    var value: HeaderValue
    if rest.len > 0:
      value = scalar(rest, ln.number)
    elif pos >= lines.len or lines[pos].indent <= indent:
      value = emptyBlock(ln.number)
    else:
      value = parseBlock(lines, pos, lines[pos].indent)
    result.mapVal.add HeaderEntry(key: key, value: value, line: ln.number)
  if pos < lines.len and lines[pos].indent < indent: return
  if pos < lines.len and lines[pos].indent > indent:
    manifestError("inconsistent manifest indentation", lines[pos].number)

proc parseList(lines: seq[SourceLine], pos: var int, indent: int): HeaderValue =
  result = HeaderValue(kind: hvList, line: lines[pos].number)
  while pos < lines.len and lines[pos].indent == indent and
      lines[pos].text.startsWith("-"):
    let ln = lines[pos]
    if ln.text.len == 1: manifestError("empty list item", ln.number)
    if not ln.text.startsWith("- "): manifestError("expected '- ' list marker", ln.number)
    let item = ln.text[2..^1].strip()
    inc pos
    # A colon inside a quoted scalar does not make the item a mapping.
    let itemColon = item.find(':')
    let mappingItem = itemColon > 0 and item[0].isAlphaAscii() and
      item[0..<itemColon].allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9', '_'})
    if mappingItem:
      let (firstKey, firstRest) = splitPair(item, ln.number)
      var map = HeaderValue(kind: hvMap, line: ln.number)
      var keys = initHashSet[string]()
      keys.incl(firstKey)
      var firstValue: HeaderValue
      if firstRest.len > 0:
        firstValue = scalar(firstRest, ln.number)
      elif pos >= lines.len or lines[pos].indent <= indent + 2:
        # A nested block must be deeper than the ALIGN column; a line at the
        # ALIGN column is the item's next key.
        firstValue = emptyBlock(ln.number)
      else:
        firstValue = parseBlock(lines, pos, lines[pos].indent)
      map.mapVal.add HeaderEntry(key: firstKey, value: firstValue, line: ln.number)
      if pos < lines.len and lines[pos].indent > indent:
        let continuationIndent = lines[pos].indent
        if continuationIndent != indent + 2:
          manifestError("list continuation keys must align with the first key",
            lines[pos].number)
        let extra = parseMap(lines, pos, continuationIndent)
        for entry in extra.mapVal:
          if entry.key in keys:
            manifestError("duplicate manifest key '" & entry.key & "'", entry.line)
          keys.incl(entry.key)
          map.mapVal.add entry
      result.listVal.add map
    else:
      result.listVal.add scalar(item, ln.number)
  if pos < lines.len and lines[pos].indent > indent:
    manifestError("inconsistent manifest indentation", lines[pos].number)

proc parseBlock(lines: seq[SourceLine], pos: var int, indent: int): HeaderValue =
  if pos >= lines.len: manifestError("missing manifest value", 1)
  if lines[pos].indent != indent:
    manifestError("inconsistent manifest indentation", lines[pos].number)
  if lines[pos].text.startsWith("-"): parseList(lines, pos, indent)
  else: parseMap(lines, pos, indent)

proc functionStart(text: string): bool =
  let brace = text.find('{')
  if brace < 0: return false
  let prefix = text[0..<brace].strip()
  if prefix.startsWith("func "): return true
  let words = prefix.splitWhitespace()
  words.len in 1..2 and ':' notin prefix

proc scanManifestCalls(input: string): seq[ManifestCall] =
  ## Validate expression calls structurally and retain each quoted argument.
  ## This intentionally scans source before interpolation; values cannot add argv.
  var i = 0
  var line = 1
  while i + 1 < input.len:
    if input[i] == '\n': inc line
    if input[i] == '$' and input[i + 1] == '{':
      let callLine = line
      i += 2
      while i < input.len and input[i] == ' ': inc i
      if i >= input.len or not (input[i].isAlphaAscii or input[i] == '_'):
        manifestError("computed expression function names are not allowed", callLine)
      var name = ""
      while i < input.len and (input[i].isAlphaNumeric or input[i] in {'_', '-'}):
        name.add input[i]; inc i
      if i < input.len and input[i] == '(':
        inc i
        var args: seq[string]
        while true:
          while i < input.len and input[i] in {' ', '\n', '\r'}:
            if input[i] == '\n': inc line
            inc i
          if i < input.len and input[i] == ')': inc i; break
          # Inside a double-quoted Kongue string the argument quotes are
          # escaped (`"${spawn(\"/bin/x\", \"-y\")}"`), so `\"` opens and
          # closes an argument just as a bare quote does elsewhere.
          let escapedQuote = i + 1 < input.len and input[i] == '\\' and
            input[i + 1] in {'"', '\''}
          if i >= input.len or (input[i] notin {'"', '\''} and not escapedQuote):
            manifestError("expression call arguments must be quoted strings", callLine)
          if escapedQuote: inc i
          let quote = input[i]; inc i
          var arg = ""
          var closed = false
          while i < input.len and input[i] != '\n':
            if escapedQuote:
              if input[i] == '\\' and i + 1 < input.len and input[i + 1] == quote:
                i += 2; closed = true; break
              if input[i] == '\\' and i + 1 < input.len and input[i + 1] == '\\':
                arg.add '\\'; i += 2; continue
              if input[i] == quote:
                manifestError("unescaped quote inside an escaped expression argument", callLine)
              arg.add input[i]; inc i
            else:
              if input[i] == quote:
                inc i; closed = true; break
              if input[i] == '\\' and i + 1 < input.len:
                arg.add input[i]; inc i
              arg.add input[i]; inc i
          if not closed: manifestError("unterminated expression argument", callLine)
          args.add arg
          while i < input.len and input[i] == ' ': inc i
          if i < input.len and input[i] == ',': inc i
          elif i < input.len and input[i] == ')': inc i; break
          else: manifestError("expected ',' or ')' in expression call", callLine)
        result.add ManifestCall(name: name, args: args, line: callLine)
      while i < input.len and input[i] != '}':
        if input[i] == '$' and i + 1 < input.len and input[i + 1] == '{':
          manifestError("computed expression names are not allowed", callLine)
        inc i
    inc i

proc validateManifestFunctions(parsed: ParsedScript) =
  var names = initHashSet[string]()
  for fn in parsed.functions:
    if fn.funcName.startsWith("init_") or fn.funcName.startsWith("shutdown_"):
      manifestError("reserved manifest function prefix", fn.line)
    if fn.funcQualifier.len > 0 and fn.funcName in ["init", "shutdown"]:
      manifestError(fn.funcName & " must not be qualified", fn.line)
    let exact = if fn.funcQualifier.len == 0: fn.funcName
                else: fn.funcName & " " & fn.funcQualifier
    let stored = if fn.funcQualifier.len == 0: fn.funcName
                 else: fn.funcName & "_" & fn.funcQualifier
    if exact in names or stored in names:
      manifestError("duplicate or colliding function name '" & exact & "'", fn.line)
    names.incl(exact); names.incl(stored)
  for fn in parsed.customFuncs:
    if fn.customFuncName == "init" or fn.customFuncName == "shutdown":
      manifestError("func " & fn.customFuncName & " is not allowed", fn.line)
    if fn.customFuncName.startsWith("init_") or
        fn.customFuncName.startsWith("shutdown_"):
      manifestError("reserved manifest function prefix", fn.line)
    if fn.customFuncName in names:
      manifestError("duplicate or colliding function name '" & fn.customFuncName & "'", fn.line)
    names.incl(fn.customFuncName)

proc parseManifest*(input: string): ParsedScript =
  ## Parse a strict manifest without evaluating or interpolating its header.
  let all = input.splitLines()
  var headerLines: seq[SourceLine]
  var bodyStart = all.len + 1
  for i, raw in all:
    if raw.len > 0 and raw[0] notin {' ', '\t'} and
        functionStart(stripComment(raw).strip()):
      bodyStart = i + 1
      break
    let ln = headerLine(raw, i + 1)
    if ln.text.len > 0: headerLines.add ln
  if headerLines.len == 0: manifestError("manifest header is empty", 1)
  if headerLines[0].indent != 0:
    manifestError("top-level manifest keys must not be indented", headerLines[0].number)
  var pos = 0
  result.manifestHeader = parseMap(headerLines, pos, 0)
  if pos != headerLines.len:
    manifestError("inconsistent manifest indentation", headerLines[pos].number)

  var body = ""
  for i in 0..<all.len:
    if i + 1 < bodyStart: body.add("\n")
    else: body.add(all[i] & "\n")
  var parsedBody: ParsedScript
  try:
    var p = initParser(tokenize(body))
    p.strict = true
    parsedBody = p.parse()
  except ParseError as e:
    manifestError(e.msg, e.line, max(e.col, 1))
  if parsedBody.variables.len > 0:
    manifestError("header fields must precede the first function block",
      parsedBody.variables[0].line)
  result.functions = parsedBody.functions
  result.customFuncs = parsedBody.customFuncs
  validateManifestFunctions(result)
  result.manifestCalls = scanManifestCalls(body)

proc parseManifestFile*(path: string): ParsedScript =
  parseManifest(readFile(path))

proc getHeader*(header: HeaderValue, key: string): HeaderValue =
  if header != nil and header.kind == hvMap:
    for entry in header.mapVal:
      if entry.key == key: return entry.value
  nil
