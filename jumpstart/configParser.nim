## Configuration Parser for Jumpstart using Kongue
## Parses .kg (Kongue) unit files for services, mounts, and timers
##
## This module provides the parsing layer that translates Kongue scripts
## into Jumpstart's internal configuration types.

import os
import strutils
import tables
import ../kongue/kongue

type
  UnitType* = enum
    utSimple = "simple"
    utOneshot = "oneshot"
    utMulti = "multi"
    utTimer = "timer"
    utMount = "mount"
    utTarget = "target"

  OnMissedBehavior* = enum
    omSkip = "skip"
    omRun = "run"

  ServiceConfig* = object
    name*: string
    exec*: string
    execPre*: string
    execPost*: string
    terminal*: bool

  TimerConfig* = object
    name*: string
    interval*: int
    service*: string
    onMissed*: OnMissedBehavior

  MountConfig* = object
    name*: string
    fromPath*: string
    toPath*: string
    fstype*: string
    timeout*: string
    lazyUnmount*: bool
    chmod*: int
    extraArgs*: string

  UnitConfig* = object
    name*: string
    description*: string
    unitType*: UnitType
    depends*: seq[string]
    after*: seq[string]
    wants*: seq[string]
    # Sub-unit specific dependencies/orderings (keyed by sub-unit name)
    subDepends*: Table[string, seq[string]]
    subAfter*: Table[string, seq[string]]
    # Unit definitions (for multi-unit files, multiple entries possible)
    services*: seq[ServiceConfig]
    timers*: seq[TimerConfig]
    mounts*: seq[MountConfig]
    # Raw declarations, kept so validation can report what parsing tolerates.
    typeName*: string          ## `type` exactly as written ("" if absent).
    hasDescription*: bool
    functionBlocks*: seq[string] ## Every function block, as `name qualifier`.

proc parseUnitTypeStr(s: string): UnitType =
  case s.toLowerAscii()
  of "simple": utSimple
  of "oneshot": utOneshot
  of "multi": utMulti
  of "timer": utTimer
  of "mount": utMount
  of "target": utTarget
  else: utSimple

proc parseOnMissed(s: string): OnMissedBehavior =
  case s.toLowerAscii()
  of "run": omRun
  else: omSkip

proc literalArg*(arg: string): string =
  ## Kongue keeps a quoted function-call argument as written, quotes and
  ## escapes included (`from "tmpfs"` yields `"tmpfs"`). Decfile commands
  ## take literal values, so a single quoted string is unquoted here;
  ## anything else (bare words, numbers) is returned unchanged.
  if arg.len < 2 or arg[0] != '"' or arg[^1] != '"': return arg
  var i = 1
  while i < arg.len - 1:
    let c = arg[i]
    if c == '\\' and i + 1 < arg.len - 1:
      case arg[i + 1]
      of 'n': result.add('\n')
      of 't': result.add('\t')
      of 'r': result.add('\r')
      of '\\': result.add('\\')
      of '"': result.add('"')
      else: result.add(c); result.add(arg[i + 1])
      i += 2
    elif c == '"':
      return arg # several strings, not one literal
    else:
      result.add(c)
      inc i

proc extractCommandArg(node: AstNode, cmdName: string): string =
  ## Extract the first argument from a function call node if it matches cmdName
  if node.kind == nkFuncCall and node.callName == cmdName and
      node.callArgs.len > 0:
    return node.callArgs[0]
  return ""

proc parseServiceBlock(funcNode: AstNode): ServiceConfig =
  ## Parse a service function block into ServiceConfig
  result = ServiceConfig(name: funcNode.funcQualifier)
  if result.name == "":
    result.name = "main"

  for stmt in funcNode.funcBody:
    case stmt.kind
    of nkExec:
      result.exec = stmt.execCmd
    of nkFuncCall:
      case stmt.callName
      of "exec":
        if stmt.callArgs.len > 0:
          result.exec = literalArg(stmt.callArgs[0])
      of "exec_pre", "execPre":
        if stmt.callArgs.len > 0:
          result.execPre = literalArg(stmt.callArgs[0])
      of "exec_post", "execPost":
        if stmt.callArgs.len > 0:
          result.execPost = literalArg(stmt.callArgs[0])
      of "terminal":
        if stmt.callArgs.len > 0:
          result.terminal = literalArg(stmt.callArgs[0]).toLowerAscii() in ["true", "yes", "1", "on"]
      else:
        discard
    else:
      discard

proc parseTimerBlock(funcNode: AstNode): TimerConfig =
  ## Parse a timer function block into TimerConfig
  result = TimerConfig(name: funcNode.funcQualifier, onMissed: omSkip)
  if result.name == "":
    result.name = "main"

  for stmt in funcNode.funcBody:
    if stmt.kind == nkFuncCall:
      case stmt.callName
      of "interval":
        if stmt.callArgs.len > 0:
          try:
            result.interval = parseInt(literalArg(stmt.callArgs[0]))
          except ValueError:
            discard
      of "service":
        if stmt.callArgs.len > 0:
          result.service = literalArg(stmt.callArgs[0])
      of "on_missed", "onMissed":
        if stmt.callArgs.len > 0:
          result.onMissed = parseOnMissed(literalArg(stmt.callArgs[0]))
      else:
        discard

proc parseMountBlock(funcNode: AstNode): MountConfig =
  ## Parse a mount function block into MountConfig
  result = MountConfig(name: funcNode.funcQualifier, chmod: 0o755)
  if result.name == "":
    result.name = "main"

  for stmt in funcNode.funcBody:
    if stmt.kind == nkFuncCall:
      case stmt.callName
      of "from":
        if stmt.callArgs.len > 0:
          result.fromPath = literalArg(stmt.callArgs[0])
      of "to":
        if stmt.callArgs.len > 0:
          result.toPath = literalArg(stmt.callArgs[0])
      of "fstype":
        if stmt.callArgs.len > 0:
          result.fstype = literalArg(stmt.callArgs[0])
      of "timeout":
        if stmt.callArgs.len > 0:
          result.timeout = literalArg(stmt.callArgs[0])
      of "lazy_unmount", "lazyUnmount":
        if stmt.callArgs.len > 0:
          result.lazyUnmount = literalArg(stmt.callArgs[0]).toLowerAscii() == "true"
      of "chmod":
        if stmt.callArgs.len > 0:
          try:
            result.chmod = parseOctInt(literalArg(stmt.callArgs[0]))
          except ValueError:
            discard
      of "extra_args", "extraArgs":
        if stmt.callArgs.len > 0:
          result.extraArgs = literalArg(stmt.callArgs[0])
      else:
        discard

proc parseUnit*(configPath: string, unitName: string): UnitConfig =
  ## Parse a .kg unit file and return a UnitConfig
  ##
  ## configPath: Base directory containing .kg files (e.g., /etc/jumpstart)
  ## unitName: Name of the unit (without .kg extension)
  result = UnitConfig(
    name: unitName,
    subDepends: initTable[string, seq[string]](),
    subAfter: initTable[string, seq[string]]()
  )

  let filePath = configPath / unitName & ".kg"
  if not fileExists(filePath):
    raise newException(IOError, "Unit file not found: " & filePath)

  let content = readFile(filePath)
  let tokens = tokenize(content)
  var parser = initParser(tokens)
  let parsed = parser.parse()

  # Extract variables
  for varNode in parsed.variables:
    case varNode.kind
    of nkVariable:
      let fullName = getFullVarName(varNode)
      case varNode.varName
      of "name":
        result.name = varNode.varValue
      of "description":
        result.description = varNode.varValue
        result.hasDescription = true
      of "type":
        result.typeName = varNode.varValue
        result.unitType = parseUnitTypeStr(varNode.varValue)
      else:
        discard
    of nkListVariable:
      case varNode.listName
      of "wants":
        if varNode.listQualifier == "":
          case varNode.listOp
          of opSet: result.wants = varNode.listItems
          of opAppend: result.wants.add(varNode.listItems)
          of opRemove:
            for item in varNode.listItems:
              let idx = result.wants.find(item)
              if idx >= 0: result.wants.delete(idx)
      of "depends":
        if varNode.listQualifier == "":
          case varNode.listOp
          of opSet: result.depends = varNode.listItems
          of opAppend: result.depends.add(varNode.listItems)
          of opRemove:
            for item in varNode.listItems:
              let idx = result.depends.find(item)
              if idx >= 0:
                result.depends.delete(idx)
        else:
          # Sub-unit dependency
          let subName = varNode.listQualifier
          if not result.subDepends.hasKey(subName):
            result.subDepends[subName] = @[]
          case varNode.listOp
          of opSet: result.subDepends[subName] = varNode.listItems
          of opAppend: result.subDepends[subName].add(varNode.listItems)
          of opRemove:
            for item in varNode.listItems:
              let idx = result.subDepends[subName].find(item)
              if idx >= 0:
                result.subDepends[subName].delete(idx)
      of "after":
        if varNode.listQualifier == "":
          case varNode.listOp
          of opSet: result.after = varNode.listItems
          of opAppend: result.after.add(varNode.listItems)
          of opRemove:
            for item in varNode.listItems:
              let idx = result.after.find(item)
              if idx >= 0:
                result.after.delete(idx)
        else:
          # Sub-unit ordering
          let subName = varNode.listQualifier
          if not result.subAfter.hasKey(subName):
            result.subAfter[subName] = @[]
          case varNode.listOp
          of opSet: result.subAfter[subName] = varNode.listItems
          of opAppend: result.subAfter[subName].add(varNode.listItems)
          of opRemove:
            for item in varNode.listItems:
              let idx = result.subAfter[subName].find(item)
              if idx >= 0:
                result.subAfter[subName].delete(idx)
      else:
        discard
    else:
      discard

  # Extract functions (service, timer, mount blocks)
  for funcNode in parsed.functions:
    if funcNode.kind == nkFunction:
      result.functionBlocks.add(
        if funcNode.funcQualifier.len == 0: funcNode.funcName
        else: funcNode.funcName & " " & funcNode.funcQualifier)
      case funcNode.funcName
      of "service":
        result.services.add(parseServiceBlock(funcNode))
      of "timer":
        result.timers.add(parseTimerBlock(funcNode))
      of "mount":
        result.mounts.add(parseMountBlock(funcNode))
      else:
        discard

proc parseUnitFile*(filePath: string): UnitConfig =
  ## Parse a .kg unit file directly by path
  let (dir, name, _) = splitFile(filePath)
  return parseUnit(dir, name)

proc getUnitKindFromConfig*(config: UnitConfig): string =
  ## Return the primary unit kind for a config
  ## Used for backwards compatibility with old naming
  case config.unitType
  of utMount: "mount"
  of utTimer: "timer"
  of utTarget, utMulti: "target"
  else: "service"

proc getAllUnitsInDir*(configPath: string): seq[string] =
  ## Get all .kg unit names in the config directory (regular files and
  ## symbolic links to files).
  result = @[]
  if dirExists(configPath):
    for kind, path in walkDir(configPath):
      if kind in {pcFile, pcLinkToFile} and path.endsWith(".kg"):
        let (_, name, _) = splitFile(path)
        result.add(name)

const validUnitTypes* = ["simple", "oneshot", "multi", "timer", "mount", "target"]

proc unitDiagnostics*(config: UnitConfig): seq[string] =
  ## Static checks of a parsed decfile against jumpstart_dec(5). Parsing is
  ## tolerant for compatibility; validation reports what it tolerated.
  if not config.hasDescription:
    result.add("missing required variable: description")
  if config.typeName.len == 0:
    result.add("missing required variable: type")
  elif config.typeName.toLowerAscii() notin validUnitTypes:
    result.add("unknown type '" & config.typeName & "' (expected one of " &
      validUnitTypes.join(", ") & ")")
    return
  case config.unitType
  of utTarget:
    if config.functionBlocks.len > 0:
      result.add("a target has no function block, found: " &
        config.functionBlocks.join(", "))
  of utSimple, utOneshot:
    if config.services.len != 1:
      result.add("a " & $config.unitType & " unit needs exactly one service block")
    elif config.services[0].exec.len == 0:
      result.add("service block has no exec command")
  of utMount:
    if config.mounts.len != 1:
      result.add("a mount unit needs exactly one mount block")
  of utTimer:
    if config.timers.len != 1:
      result.add("a timer unit needs exactly one timer block")
  of utMulti:
    if config.services.len + config.mounts.len + config.timers.len == 0:
      result.add("a multi unit needs at least one named service, mount, or timer block")
    var seen: seq[string]
    for name in (block:
        var names: seq[string]
        for item in config.services: names.add(item.name)
        for item in config.mounts: names.add(item.name)
        for item in config.timers: names.add(item.name)
        names):
      if name in seen: result.add("duplicate sub-unit name: " & name)
      else: seen.add(name)
  for svc in config.services:
    if config.unitType == utMulti and svc.exec.len == 0:
      result.add("service " & svc.name & " has no exec command")
  for mnt in config.mounts:
    if mnt.fromPath.len == 0 or mnt.toPath.len == 0 or mnt.fstype.len == 0:
      result.add("mount " & mnt.name & " is missing from, to, or fstype")
  for tmr in config.timers:
    if tmr.interval <= 0:
      result.add("timer " & tmr.name & " needs a positive interval")
    if tmr.service.isEmptyOrWhitespace:
      result.add("timer " & tmr.name & " has no service")
