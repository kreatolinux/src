## Strict declarative Kongue documents used by rootfs config and state.
## Only scalar and list declarations are accepted. Kongue execution syntax,
## qualifiers, mutation operators, interpolation, and duplicate keys are denied.
import std/[sets, tables]
import ./types
import ../../../kongue/lexer

proc fail(path: string, token: Token, message: string) {.noreturn.} =
  raise newException(DeclarativeKongueError, path & ":" & $token.line & ":" &
      $token.col & ": " & message)

proc isValue(kind: TokenKind): bool =
  kind in {tkString, tkIdentifier, tkNumber}

proc parseDeclarativeKongue*(content: string, path = "<memory>"): KongueDocument =
  let tokens = tokenize(content)
  var seen = initHashSet[string]()
  var pos = 0

  template current: Token = tokens[pos]
  proc skipTrivia() =
    while pos < tokens.len and tokens[pos].kind in {tkNewline, tkComment}:
      inc pos

  skipTrivia()
  while pos < tokens.len and current.kind != tkEof:
    let nameToken = current
    if nameToken.kind != tkIdentifier:
      fail(path, nameToken,
          "only declarative Kongue scalar and list fields are permitted")
    let name = nameToken.value
    if name in seen:
      fail(path, nameToken, "duplicate field '" & name & "'")
    seen.incl(name)
    inc pos
    if pos >= tokens.len or current.kind != tkColon:
      fail(path, current, "expected ':' after field '" & name & "'")
    inc pos

    if pos < tokens.len and current.kind == tkNewline:
      while pos < tokens.len and current.kind == tkNewline: inc pos
      var items: seq[string]
      while pos < tokens.len and current.kind == tkDash:
        inc pos
        if pos >= tokens.len or not isValue(current.kind):
          fail(path, current, "expected a literal list item")
        let itemToken = current
        if '$' in itemToken.value:
          fail(path, itemToken, "interpolation is not permitted")
        items.add(itemToken.value)
        inc pos
        if pos < tokens.len and current.kind notin {tkNewline, tkComment, tkEof}:
          fail(path, current, "unexpected token after list item")
        while pos < tokens.len and current.kind in {tkNewline, tkComment}: inc pos
      result.lists[name] = items
    else:
      if pos >= tokens.len or not isValue(current.kind):
        fail(path, current, "expected a literal value for '" & name & "'")
      let valueToken = current
      if '$' in valueToken.value:
        fail(path, valueToken, "interpolation is not permitted")
      result.scalars[name] = valueToken.value
      inc pos
      if pos < tokens.len and current.kind notin {tkNewline, tkComment, tkEof}:
        fail(path, current, "unexpected token after field '" & name & "'")
      skipTrivia()

proc loadDeclarativeKongue*(path: string): KongueDocument =
  parseDeclarativeKongue(readFile(path), path)

proc requireKnownFields*(doc: KongueDocument, path: string,
    scalarFields, listFields: openArray[string]) =
  let scalarSet = scalarFields.toHashSet()
  let listSet = listFields.toHashSet()
  for key in doc.scalars.keys:
    if key notin scalarSet:
      raise newException(DeclarativeKongueError,
          path & ": unknown scalar field '" & key & "'")
  for key in doc.lists.keys:
    if key notin listSet:
      raise newException(DeclarativeKongueError,
          path & ": unknown list field '" & key & "'")

proc scalar*(doc: KongueDocument, key: string, default = ""): string =
  doc.scalars.getOrDefault(key, default)

proc list*(doc: KongueDocument, key: string): seq[string] =
  doc.lists.getOrDefault(key)
