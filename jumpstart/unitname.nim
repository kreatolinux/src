import strutils

const legacyUnitSuffixes = [".service", ".mount", ".timer"]

proc normalizeUnitName*(name: string): string =
  ## Return the definition name used by the unified .kg unit layout.
  ## Legacy suffixes remain accepted at the CLI boundary for compatibility.
  let qualified = name.split("::", 1)
  var base = qualified[0]

  if base.endsWith(".kg"):
    base.removeSuffix(".kg")
  else:
    for suffix in legacyUnitSuffixes:
      if base.endsWith(suffix):
        base.removeSuffix(suffix)
        break

  if qualified.len == 2:
    result = base & "::" & qualified[1]
  else:
    result = base

proc unitBaseName*(name: string): string =
  ## Strip a sub-unit qualifier and return the containing .kg definition name.
  normalizeUnitName(name).split("::", 1)[0]
