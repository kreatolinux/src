import strutils
import configParser
import types
import unitname

proc requestedUnitKind*(config: UnitConfig, requestedName: string): UnitKind =
  ## Resolve a simple unit or a qualified multi-unit member to its runtime kind.
  let normalized = normalizeUnitName(requestedName)
  if "::" notin normalized:
    case config.unitType
    of utMount: return ukMount
    of utTimer: return ukTimer
    of utSimple, utOneshot: return ukService
    of utMulti:
      raise newException(ValueError,
        "Multi-unit " & normalized & " requires a qualified sub-unit name")

  let subName = normalized.split("::", 1)[1]
  var matches: seq[UnitKind]
  for service in config.services:
    if service.name == subName:
      matches.add(ukService)
  for mount in config.mounts:
    if mount.name == subName:
      matches.add(ukMount)
  for timer in config.timers:
    if timer.name == subName:
      matches.add(ukTimer)

  if matches.len == 0:
    raise newException(ValueError, "Sub-unit not found: " & normalized)
  if matches.len > 1:
    raise newException(ValueError, "Ambiguous sub-unit name: " & normalized)
  result = matches[0]
