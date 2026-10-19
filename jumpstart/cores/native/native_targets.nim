## Native target model for serviceHandler (jumpstart-cores specification, section 22).
##
## This module deliberately has no dependency on the serviceHandler runtime.  All
## roots are injected and activation/isolation are returned as plans, which makes
## the policy usable by the daemon without performing process operations here.
import std/[algorithm, os, sets, strutils, tables, times]

type
  NativeUnitKind* = enum
    nukService, nukMount, nukTimer, nukTarget, nukMulti

  NativeUnit* = object
    name*: string
    kind*: NativeUnitKind
    wants*: seq[string]       ## Fixed target members.
    members*: seq[string]     ## Sub-units of a multi definition.
    depends*: seq[string]     ## Hard dependencies.
    after*: seq[string]       ## Soft ordering constraints.
    memberKinds*: seq[NativeUnitKind] ## Kinds of `members`, same order.
                                      ## Missing entries mean `nukService`.
    subDepends*: Table[string, seq[string]] ## Per sub-unit hard dependencies.
    subAfter*: Table[string, seq[string]]   ## Per sub-unit ordering.
    oneshot*: bool            ## A `oneshot` service decfile (§22.5).

  NativeEnablement* = enum
    neDisabled, neStatic, neEnabled

  NativeTargetError* = object of ValueError
    code*: string

  NativeTargetModel* = object
    configRoot*: string
    units*: Table[string, NativeUnit]

  IsolationPlan* = object
    start*: seq[string]
    stop*: seq[string]
    keep*: seq[string]

  NativeDiagnostic* = object
    name*: string             ## Unit the diagnostic is about ("" if global).
    code*: string
    message*: string

  ActivationReport* = object
    plan*: seq[string]        ## Startable units in dependency/after order.
    failed*: seq[NativeDiagnostic] ## Units left out, with the reason.

const
  BuiltinDefaultTarget* = "default"

proc fail(code, message: string) {.noreturn.} =
  var e = newException(NativeTargetError, message)
  e.code = code
  raise e

proc definitionName*(name: string): string =
  ## Return the decfile portion of a possibly qualified native name.
  let p = name.find("::")
  if p < 0: name else: name[0 ..< p]

proc isSubUnit*(name: string): bool = name.find("::") >= 0

proc validNativeName(name: string; qualified = true): bool =
  if name.len == 0 or name[0] == '-' or name.len > 255: return false
  if name.contains('/') or name.contains("\0"): return false
  for c in name:
    if c <= '\x20' or c == '\x7f': return false
  if not qualified and name.contains("::"): return false
  true

proc initNativeTargetModel*(configRoot: string,
                            units: openArray[NativeUnit] = []): NativeTargetModel =
  result.configRoot = configRoot
  result.units = initTable[string, NativeUnit]()
  for unit in units:
    if not validNativeName(unit.name, false):
      fail("E_NAME", "invalid native unit name: " & unit.name)
    if unit.name == BuiltinDefaultTarget:
      fail("E_UNIT_STATE", "default is a reserved built-in target")
    if result.units.hasKey(unit.name):
      fail("E_UNIT_STATE", "duplicate native unit: " & unit.name)
    result.units[unit.name] = unit

proc addUnit*(model: var NativeTargetModel, unit: NativeUnit) =
  if not validNativeName(unit.name, false):
    fail("E_NAME", "invalid native unit name: " & unit.name)
  if unit.name == BuiltinDefaultTarget:
    fail("E_UNIT_STATE", "default is a reserved built-in target")
  if model.units.hasKey(unit.name):
    fail("E_UNIT_STATE", "duplicate native unit: " & unit.name)
  model.units[unit.name] = unit

proc hasUnit*(model: NativeTargetModel, name: string): bool =
  if name == BuiltinDefaultTarget: return true
  let base = definitionName(name)
  if not model.units.hasKey(base): return false
  not isSubUnit(name) or name in model.units[base].members

proc isTarget*(model: NativeTargetModel, name: string): bool =
  if name == BuiltinDefaultTarget: return true
  if isSubUnit(name) or not model.units.hasKey(name): return false
  model.units[name].kind in {nukTarget, nukMulti}

proc memberKind*(unit: NativeUnit, member: string): NativeUnitKind =
  ## Kind of a sub-unit of a multi definition (`nukService` when unrecorded).
  let at = unit.members.find(member)
  if at >= 0 and at < unit.memberKinds.len: unit.memberKinds[at] else: nukService

proc kindOf*(model: NativeTargetModel, name: string): NativeUnitKind =
  ## Kind of a known unit or sub-unit. The built-in default is a target.
  if name == BuiltinDefaultTarget: return nukTarget
  let base = definitionName(name)
  if not model.units.hasKey(base): fail("E_UNIT_NOT_FOUND", "unknown unit: " & name)
  if isSubUnit(name):
    if name notin model.units[base].members:
      fail("E_UNIT_NOT_FOUND", "unknown sub-unit: " & name)
    return model.units[base].memberKind(name)
  model.units[base].kind

proc subsystem*(model: NativeTargetModel, name: string): string =
  ## Multi containers resolve as targets; qualified children resolve by their
  ## own function block (service, mount or timer).
  if not model.hasUnit(name): return ""
  case model.kindOf(name)
  of nukService: "service"
  of nukMount: "mount"
  of nukTimer: "timer"
  of nukTarget, nukMulti: "target"

proc linkPresent(path: string): bool = fileExists(path) or symlinkExists(path)

proc linkedNames(dir: string): seq[string] =
  if not dirExists(dir): return
  for kind, path in walkDir(dir):
    if kind in {pcFile, pcLinkToFile, pcLinkToDir} or symlinkExists(path):
      let (_, name, ext) = splitFile(path)
      if ext == ".kg": result.add(name)
  result.sort(system.cmp[string])
  var unique: seq[string]
  for item in result:
    if unique.len == 0 or unique[^1] != item: unique.add(item)
  result = unique

proc directMembers*(model: NativeTargetModel, target: string): seq[string] =
  ## Fixed wants followed by enabled members, de-duplicated in stable order.
  if not model.isTarget(target):
    fail("E_UNIT_NOT_FOUND", "not a native target: " & target)
  var seen = initHashSet[string]()
  template addUnique(value: string) =
    let item = value
    if item notin seen:
      seen.incl(item)
      result.add(item)
  if target == BuiltinDefaultTarget:
    for item in linkedNames(model.configRoot / "enabled"): addUnique(item)
  else:
    let unit = model.units[target]
    if unit.kind == nukMulti:
      for item in unit.members: addUnique(item)
    else:
      for item in unit.wants: addUnique(item)
    for item in linkedNames(model.configRoot / "targets" / target): addUnique(item)

proc transitiveMembers*(model: NativeTargetModel, target: string): seq[string] =
  ## Flatten nested targets. Target names themselves are not executable members.
  var visiting, expanded, emitted = initHashSet[string]()
  var stack, output: seq[string]
  proc visit(name: string) =
    if model.isTarget(name):
      if name in visiting:
        let at = stack.find(name)
        let cycle = (if at >= 0: stack[at .. ^1] & name else: @[name, name])
        fail("E_UNIT_STATE", "native target cycle: " & cycle.join(" -> "))
      if name in expanded: return
      visiting.incl(name); stack.add(name)
      for member in model.directMembers(name): visit(member)
      discard stack.pop(); visiting.excl(name); expanded.incl(name)
    elif name notin emitted:
      emitted.incl(name); output.add(name)
  visit(target)
  result = output

proc targetCycle*(model: NativeTargetModel): seq[string] =
  ## Return one target cycle (with repeated closing node), or an empty sequence.
  var visiting, visited = initHashSet[string]()
  var stack, found: seq[string]
  proc visit(name: string): bool =
    if name in visiting:
      let at = stack.find(name)
      found = (if at >= 0: stack[at .. ^1] & name else: @[name, name])
      return true
    if name in visited: return false
    visiting.incl(name); stack.add(name)
    for member in model.directMembers(name):
      if model.isTarget(member) and visit(member): return true
    discard stack.pop(); visiting.excl(name); visited.incl(name)
  var targets = @[BuiltinDefaultTarget]
  for name, unit in model.units:
    if unit.kind in {nukTarget, nukMulti}: targets.add(name)
  targets.sort(system.cmp[string])
  for name in targets:
    if visit(name): return found

proc reservedDefaultPresent*(model: NativeTargetModel): bool =
  fileExists(model.configRoot / "default.kg") or
    symlinkExists(model.configRoot / "default.kg")

proc reservedDefaultDiagnostic*(): NativeDiagnostic =
  NativeDiagnostic(name: BuiltinDefaultTarget & ".kg", code: "E_UNIT_STATE",
    message: "default.kg uses the reserved built-in target name 'default'; " &
      "it is not loaded and never starts (rename it and its enabled/ link)")

proc targetDiagnostics*(model: NativeTargetModel,
                        target: string): seq[NativeDiagnostic] =
  ## Unknown members of one target. Cycles are reported by validationErrors.
  for member in model.directMembers(target):
    if not model.hasUnit(member):
      result.add NativeDiagnostic(name: target, code: "E_UNIT_NOT_FOUND",
        message: target & " wants unknown unit " & member)

proc validationErrors*(model: NativeTargetModel): seq[NativeDiagnostic] =
  ## Every target-level problem, not just the first one: a reserved
  ## `default.kg`, unknown members of each target, and one target cycle.
  if model.reservedDefaultPresent: result.add reservedDefaultDiagnostic()
  var targets = @[BuiltinDefaultTarget]
  for name, unit in model.units:
    if unit.kind in {nukTarget, nukMulti}: targets.add(name)
  targets.sort(system.cmp[string])
  for target in targets: result.add model.targetDiagnostics(target)
  let cycle = model.targetCycle()
  if cycle.len > 0:
    result.add NativeDiagnostic(name: cycle[0], code: "E_UNIT_STATE",
      message: "native target cycle: " & cycle.join(" -> "))

proc validateTargets*(model: NativeTargetModel) =
  ## Raise when validationErrors is not empty. The error carries the code of
  ## the first problem and the messages of all of them.
  let errors = model.validationErrors()
  if errors.len > 0:
    var messages: seq[string]
    for item in errors: messages.add(item.message)
    fail(errors[0].code, messages.join("; "))

proc enabledAnywhere(model: NativeTargetModel, base: string): bool =
  if linkPresent(model.configRoot / "enabled" / (base & ".kg")): return true
  let root = model.configRoot / "targets"
  if dirExists(root):
    for kind, path in walkDir(root):
      if kind == pcDir and linkPresent(path / (base & ".kg")): return true
  false

proc wantedAnywhere(model: NativeTargetModel, name: string): bool =
  for _, unit in model.units:
    if unit.kind == nukTarget and name in unit.wants: return true
    if unit.kind == nukMulti and name in unit.members: return true
  false

proc enablement*(model: NativeTargetModel, name: string): NativeEnablement =
  let base = definitionName(name)
  if model.enabledAnywhere(base): neEnabled
  elif model.wantedAnywhere(name) or (not isSubUnit(name) and model.wantedAnywhere(base)):
    neStatic
  else: neDisabled

proc linkPath(model: NativeTargetModel, unit, target: string): string =
  if target == BuiltinDefaultTarget:
    model.configRoot / "enabled" / (unit & ".kg")
  else:
    model.configRoot / "targets" / target / (unit & ".kg")

proc enable*(model: NativeTargetModel, unit: string,
             target = BuiltinDefaultTarget) =
  if isSubUnit(unit):
    fail("E_UNSUPPORTED", "cannot enable sub-unit; enable " & definitionName(unit))
  if not model.units.hasKey(unit): fail("E_UNIT_NOT_FOUND", "unknown unit: " & unit)
  if not model.isTarget(target): fail("E_UNIT_NOT_FOUND", "not a target: " & target)
  let destination = model.linkPath(unit, target)
  if linkPresent(destination): return
  createDir(parentDir(destination))
  createSymlink(model.configRoot / (unit & ".kg"), destination)
  try:
    let cycle = model.targetCycle()
    if cycle.len > 0:
      removeFile(destination)
      fail("E_UNIT_STATE", "native target cycle: " & cycle.join(" -> "))
  except CatchableError:
    if linkPresent(destination): removeFile(destination)
    raise

proc disable*(model: NativeTargetModel, unit: string,
              target = BuiltinDefaultTarget) =
  if isSubUnit(unit):
    fail("E_UNSUPPORTED", "cannot disable sub-unit; disable " & definitionName(unit))
  let path = model.linkPath(unit, target)
  if linkPresent(path): removeFile(path)

proc getDefaultTarget*(model: NativeTargetModel): string =
  let path = model.configRoot / "default-target"
  if not fileExists(path): return BuiltinDefaultTarget
  let contents = readFile(path)
  if not contents.endsWith("\n"):
    fail("E_UNIT_STATE", "default-target must contain one target name and newline")
  result = contents[0 ..< contents.len - 1]
  if result.len == 0 or result.contains('\n') or result.contains('\r'):
    fail("E_UNIT_STATE", "default-target must contain one target name and newline")
  if not model.isTarget(result):
    fail("E_UNIT_NOT_FOUND", "default target does not exist: " & result)

proc setDefaultTarget*(model: NativeTargetModel, target: string) =
  if not model.isTarget(target): fail("E_UNIT_NOT_FOUND", "not a target: " & target)
  createDir(model.configRoot)
  let finalPath = model.configRoot / "default-target"
  let temporary = finalPath & ".tmp-" & $getCurrentProcessId() & "-" & $epochTime()
  try:
    writeFile(temporary, target & "\n")
    moveFile(temporary, finalPath)
  finally:
    if fileExists(temporary): removeFile(temporary)

proc hardDependencies*(model: NativeTargetModel, name: string): seq[string] =
  ## `depends` of the decfile plus `depends SUB` of a sub-unit.
  let base = definitionName(name)
  if not model.units.hasKey(base): return
  let unit = model.units[base]
  result = unit.depends
  if isSubUnit(name):
    let sub = name[base.len + 2 .. ^1]
    for dep in unit.subDepends.getOrDefault(sub): result.add(dep)

proc orderingAfter*(model: NativeTargetModel, name: string): seq[string] =
  ## `after` of the decfile plus `after SUB` of a sub-unit.
  let base = definitionName(name)
  if not model.units.hasKey(base): return
  let unit = model.units[base]
  result = unit.after
  if isSubUnit(name):
    let sub = name[base.len + 2 .. ^1]
    for dep in unit.subAfter.getOrDefault(sub): result.add(dep)

proc closureFrom(model: NativeTargetModel, roots: seq[string];
                 failed: var seq[NativeDiagnostic]): HashSet[string] =
  ## Executable units reachable from roots through target membership and
  ## `depends`. A unit whose dependency closure contains an unknown unit is
  ## left out and reported in `failed` (once per unit).
  var closure = initHashSet[string]()
  var found: seq[NativeDiagnostic]
  var reported = initHashSet[string]()
  var broken = initTable[string, string]()
  var visiting = initHashSet[string]()
  proc visit(name: string): string =
    ## Returns "" when `name` is startable, otherwise why it is not.
    if name in closure: return ""
    if broken.hasKey(name): return broken[name]
    if name in visiting: return ""   # dependency cycles are reported by ordering
    if not model.hasUnit(name):
      return "unknown unit: " & name
    if model.isTarget(name):
      visiting.incl(name)
      for member in model.directMembers(name):
        let why = visit(member)
        if why.len > 0 and not model.isTarget(member) and member notin reported:
          broken[member] = why
          reported.incl(member)
          found.add NativeDiagnostic(name: member, code: "E_UNIT_NOT_FOUND",
                                      message: why)
      visiting.excl(name)
      return ""
    visiting.incl(name)
    var reason = ""
    for dep in model.hardDependencies(name):
      let why = visit(dep)
      if why.len > 0 and reason.len == 0:
        reason = name & " depends on " & dep & ": " & why
    visiting.excl(name)
    if reason.len > 0:
      broken[name] = reason
      return reason
    closure.incl(name)
    ""
  for root in roots:
    let why = visit(root)
    if why.len > 0 and root notin reported:
      reported.incl(root)
      found.add NativeDiagnostic(name: root, code: "E_UNIT_NOT_FOUND", message: why)
  failed.add(found)
  result = closure

proc dependencyClosure(model: NativeTargetModel, roots: seq[string]): HashSet[string] =
  var failed: seq[NativeDiagnostic]
  result = model.closureFrom(roots, failed)
  if failed.len > 0: fail(failed[0].code, failed[0].message)

proc requiredUnits*(model: NativeTargetModel, target: string): HashSet[string] =
  ## Everything a target requires: its transitive members and their `depends`
  ## closure. Unknown units are ignored here; activation reports them.
  var failed: seq[NativeDiagnostic]
  model.closureFrom(@[target], failed)

proc kindRank(model: NativeTargetModel, name: string): int =
  ## Sub-units of one multi decfile start mounts first, then services, then
  ## timers, as `jumpstart_dec(5)` documents.
  if not isSubUnit(name): return 0
  case model.kindOf(name)
  of nukMount: 0
  of nukService: 1
  of nukTimer: 2
  else: 1

proc orderUnits(model: NativeTargetModel, nodes: HashSet[string],
                what: string): seq[string] =
  ## Topological order by depends/after and the multi sub-unit kind order.
  ## Byte order breaks ties.
  var indegree = initTable[string, int]()
  var outgoing = initTable[string, seq[string]]()
  for node in nodes: indegree[node] = 0
  proc edge(predecessor, node: string) =
    if predecessor in nodes and predecessor != node:
      if node notin outgoing.mgetOrPut(predecessor, @[]):
        outgoing[predecessor].add(node)
        indegree[node] = indegree[node] + 1
  for node in nodes:
    for predecessor in model.hardDependencies(node) & model.orderingAfter(node):
      edge(predecessor, node)
    if isSubUnit(node):
      for sibling in nodes:
        if sibling != node and isSubUnit(sibling) and
            definitionName(sibling) == definitionName(node) and
            model.kindRank(sibling) < model.kindRank(node):
          edge(sibling, node)
  var ready: seq[string]
  for node, degree in indegree:
    if degree == 0: ready.add(node)
  ready.sort(system.cmp[string])
  while ready.len > 0:
    let node = ready[0]; ready.delete(0); result.add(node)
    var next = outgoing.getOrDefault(node)
    next.sort(system.cmp[string])
    for dependent in next:
      dec indegree[dependent]
      if indegree[dependent] == 0:
        ready.add(dependent); ready.sort(system.cmp[string])
  if result.len != nodes.len:
    fail("E_UNIT_STATE", "dependency/ordering cycle while planning " & what)

proc activationReport*(model: NativeTargetModel, target: string): ActivationReport =
  ## Like activationPlan, but units with an unknown unit in their dependency
  ## closure are left out and listed in `failed` instead of failing the whole
  ## target. Target cycles and ordering cycles still raise E_UNIT_STATE.
  discard model.transitiveMembers(target) # also checks target cycles
  let nodes = model.closureFrom(@[target], result.failed)
  result.plan = model.orderUnits(nodes, "target " & target)

proc activationPlan*(model: NativeTargetModel, target: string): seq[string] =
  ## Executable units in dependency/after order. Byte order breaks ties.
  discard model.transitiveMembers(target) # also checks target cycles
  let nodes = model.dependencyClosure(@[target])
  model.orderUnits(nodes, "target " & target)

proc unitPlan*(model: NativeTargetModel, unit: string): seq[string] =
  ## Start order of a single non-target unit and its `depends` closure.
  let nodes = model.dependencyClosure(@[unit])
  model.orderUnits(nodes, "unit " & unit)


proc deactivationPlanForTarget*(model: NativeTargetModel, target: string,
                                startHistory: openArray[string],
                                active: openArray[string] = []): seq[string] =
  ## The target's transitive members that are in `startHistory` or `active`,
  ## in reverse actual start order; active members never seen starting follow
  ## in reverse byte order.
  let members = model.transitiveMembers(target).toHashSet()
  var seen = initHashSet[string]()
  for i in countdown(startHistory.high, 0):
    let unit = startHistory[i]
    if unit in members and unit notin seen:
      seen.incl(unit); result.add(unit)
  var rest: seq[string]
  for unit in active:
    if unit in members and unit notin seen:
      seen.incl(unit); rest.add(unit)
  rest.sort(system.cmp[string], SortOrder.Descending)
  result.add(rest)

proc isolationPlan*(model: NativeTargetModel, target: string,
                    active, startHistory: openArray[string]): IsolationPlan =
  result.start = model.activationReport(target).plan
  let keepSet = model.requiredUnits(target)
  for unit in result.start:
    if unit in keepSet: result.keep.add(unit)
  var activeSet = active.toHashSet()
  var considered = initHashSet[string]()
  for i in countdown(startHistory.high, 0):
    let unit = startHistory[i]
    if unit in activeSet and unit notin keepSet and unit notin considered:
      result.stop.add(unit); considered.incl(unit)
  var remaining: seq[string]
  for unit in activeSet:
    if unit notin keepSet and unit notin considered: remaining.add(unit)
  remaining.sort(system.cmp[string], SortOrder.Descending)
  result.stop.add(remaining)

proc deactivationPlan*(startHistory, active: openArray[string]): seq[string] =
  ## Active units in reverse start order, then active units that never appear
  ## in the history in reverse byte order. A unit in the history that is not
  ## active is never planned, so nothing active means an empty plan.
  var seen = initHashSet[string]()
  let activeSet = active.toHashSet()
  for i in countdown(startHistory.high, 0):
    let unit = startHistory[i]
    if unit notin seen and unit in activeSet:
      seen.incl(unit); result.add(unit)
  var rest: seq[string]
  for unit in active:
    if unit notin seen:
      seen.incl(unit); rest.add(unit)
  rest.sort(system.cmp[string], SortOrder.Descending)
  result.add(rest)
