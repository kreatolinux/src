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

  OnMissedBehavior* = enum
    omSkip = "skip"
    omRun = "run"

  ServiceConfig* = object
    name*: string
    exec*: string
    execPre*: string
    execPost*: string

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
    # Sub-unit specific dependencies/orderings (keyed by sub-unit name)
    subDepends*: Table[string, seq[string]]
    subAfter*: Table[string, seq[string]]
    # Unit definitions (for multi-unit files, multiple entries possible)
    services*: seq[ServiceConfig]
    timers*: seq[TimerConfig]
    mounts*: seq[MountConfig]

proc parseUnitTypeStr(s: string): UnitType =
  case s.toLowerAscii()
  of "simple": utSimple
  of "oneshot": utOneshot
  of "multi": utMulti
  of "timer": utTimer
  of "mount": utMount
  else: utSimple

proc parseOnMissed(s: string): OnMissedBehavior =
  case s.toLowerAscii()
  of "run": omRun
  else: omSkip

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
          result.exec = stmt.callArgs[0]
      of "exec_pre", "execPre":
        if stmt.callArgs.len > 0:
          result.execPre = stmt.callArgs[0]
      of "exec_post", "execPost":
        if stmt.callArgs.len > 0:
          result.execPost = stmt.callArgs[0]
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
            result.interval = parseInt(stmt.callArgs[0])
          except ValueError:
            discard
      of "service":
        if stmt.callArgs.len > 0:
          result.service = stmt.callArgs[0]
      of "on_missed", "onMissed":
        if stmt.callArgs.len > 0:
          result.onMissed = parseOnMissed(stmt.callArgs[0])
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
          result.fromPath = stmt.callArgs[0]
      of "to":
        if stmt.callArgs.len > 0:
          result.toPath = stmt.callArgs[0]
      of "fstype":
        if stmt.callArgs.len > 0:
          result.fstype = stmt.callArgs[0]
      of "timeout":
        if stmt.callArgs.len > 0:
          result.timeout = stmt.callArgs[0]
      of "lazy_unmount", "lazyUnmount":
        if stmt.callArgs.len > 0:
          result.lazyUnmount = stmt.callArgs[0].toLowerAscii() == "true"
      of "chmod":
        if stmt.callArgs.len > 0:
          try:
            result.chmod = parseOctInt(stmt.callArgs[0])
          except ValueError:
            discard
      of "extra_args", "extraArgs":
        if stmt.callArgs.len > 0:
          result.extraArgs = stmt.callArgs[0]
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
      of "type":
        result.unitType = parseUnitTypeStr(varNode.varValue)
      else:
        discard
    of nkListVariable:
      case varNode.listName
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
  else: "service"

proc getAllUnitsInDir*(configPath: string): seq[string] =
  ## Get all .kg unit names in the config directory
  result = @[]
  if dirExists(configPath):
    for kind, path in walkDir(configPath):
      if kind == pcFile and path.endsWith(".kg"):
        let (_, name, _) = splitFile(path)
        result.add(name)
