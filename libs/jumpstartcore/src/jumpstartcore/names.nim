## Core names, opaque unit names, operation names, and unit references.
import std/[strutils, unicode]

const
  ReservedCoreNames* = ["serviceHandler", "jumpstart", "native", "all", "none"]
  ReservedSubsystemNames* = ["boot", "device", "home", "hostname", "login",
    "network", "power", "resolve", "scope", "slice", "sysusers", "time",
    "tmpfiles"]

type
  UnitRef* = object
    qualified*: bool
    core*: string
    unit*: string

proc isAsciiLetter(c: char): bool {.inline.} =
  c in {'A'..'Z', 'a'..'z'}

proc validCoreName*(name: string, extension = true): bool =
  if name.len < 1 or name.len > 64 or not name[0].isAsciiLetter:
    return false
  for c in name:
    if not (c.isAsciiLetter or c in {'0'..'9', '_', '-'}):
      return false
  not extension or name notin ReservedCoreNames

proc validUnitName*(name: string): bool =
  ## §14.1. A name MAY begin with `-` (systemd's `-.mount` and `-.slice`);
  ## `jumpctl` accepts such a name only after `--` (§21.1).
  if name.len < 1 or name.len > 255 or name.validateUtf8 != -1:
    return false
  for c in name:
    if c == '/' or c <= '\x1f' or c == '\x7f':
      return false
  # Decode only to classify Unicode whitespace. No normalization or other
  # interpretation is performed: accepted names retain their exact bytes.
  for rune in name.runes:
    if rune.isWhiteSpace:
      return false
  true

proc validOperationPart(part: string): bool =
  if part.len == 0 or part[0] notin {'a'..'z'}:
    return false
  for c in part:
    if c notin {'a'..'z', '0'..'9', '-'}:
      return false
  true

proc validOperationName*(name: string): bool =
  let dot = name.find('.')
  dot > 0 and dot == name.rfind('.') and
    validOperationPart(name[0 ..< dot]) and validOperationPart(name[dot + 1 .. ^1])

proc operationSubsystem*(name: string): string =
  let dot = name.find('.')
  if dot < 0: "" else: name[0 ..< dot]

proc isReservedSubsystem*(name: string): bool = name in ReservedSubsystemNames

proc parseUnitRef*(reference: string): UnitRef =
  let slash = reference.find('/')
  if slash < 0:
    if not validUnitName(reference):
      raise newException(ValueError, "invalid unit name")
    return UnitRef(unit: reference)
  let core = reference[0 ..< slash]
  let unit = reference[slash + 1 .. ^1]
  if not validCoreName(core, extension = false):
    raise newException(ValueError, "invalid core name in unit reference")
  if not validUnitName(unit):
    raise newException(ValueError, "invalid unit name in unit reference")
  UnitRef(qualified: true, core: core, unit: unit)
