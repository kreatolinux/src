## Shared upstream-version normalization and comparison helpers.
import std/[strutils]

type VersionToken = object
  numeric: bool
  number: string
  text: string

proc stripLeadingZeros(value: string): string =
  var first = 0
  while first < value.high and value[first] == '0': inc first
  result = value[first .. ^1]

proc tokens(value: string): seq[VersionToken] =
  var i = 0
  while i < value.len:
    if value[i].isDigit:
      var part = ""
      while i < value.len and value[i].isDigit:
        part.add(value[i]); inc i
      result.add VersionToken(numeric: true, number: stripLeadingZeros(part))
    elif value[i].isAlphaAscii:
      var part = ""
      while i < value.len and value[i].isAlphaAscii:
        part.add(value[i].toLowerAscii); inc i
      result.add VersionToken(text: part)
    else:
      inc i

proc prereleaseRank(text: string): int =
  case text
  of "dev", "snapshot", "nightly": 0
  of "alpha", "a": 1
  of "beta", "b": 2
  of "pre", "preview": 3
  of "rc": 4
  else: 5

proc isPrereleaseToken(text: string): bool = prereleaseRank(text) < 5

proc isPrerelease*(version: string): bool =
  for token in tokens(version):
    if not token.numeric and isPrereleaseToken(token.text): return true

proc compareUpstreamVersions*(left, right: string): int =
  ## Natural comparison with arbitrary-size numeric components. Known
  ## prerelease markers sort below the corresponding final release.
  let a = tokens(left)
  let b = tokens(right)
  var i = 0
  while i < min(a.len, b.len):
    if a[i].numeric and b[i].numeric:
      if a[i].number.len != b[i].number.len:
        return cmp(a[i].number.len, b[i].number.len)
      let c = cmp(a[i].number, b[i].number)
      if c != 0: return c
    elif not a[i].numeric and not b[i].numeric:
      let ar = prereleaseRank(a[i].text)
      let br = prereleaseRank(b[i].text)
      if ar != br: return cmp(ar, br)
      let c = cmp(a[i].text, b[i].text)
      if c != 0: return c
    else:
      # Numeric components sort after textual qualifiers.
      return (if a[i].numeric: 1 else: -1)
    inc i

  if a.len == b.len: return 0
  let remainder = if i < a.len: a[i .. ^1] else: b[i .. ^1]
  var onlyZero = true
  var hasPrerelease = false
  for token in remainder:
    if token.numeric:
      if token.number != "0": onlyZero = false
    else:
      onlyZero = false
      if isPrereleaseToken(token.text): hasPrerelease = true
  if onlyZero: return 0
  let longerResult = if a.len > b.len: 1 else: -1
  if hasPrerelease: return -longerResult
  longerResult
