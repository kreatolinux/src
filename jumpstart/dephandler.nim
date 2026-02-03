## Dependency Handler for Jumpstart
## Handles dependency resolution and ordering for unit startup
##
## This is a simpler model than kpkg's dephandler since:
## - Units only depend on other units by name
## - No version constraints
## - No build vs runtime distinction (all are runtime)
## - `depends` = hard dependency (fails if not running)
## - `after` = soft ordering (just waits, doesn't fail if missing)

import os
import sets
import tables
import strutils
import configParser
include commonImports

type
  DependencyGraph* = object
    ## Graph of unit dependencies
    nodes*: HashSet[string]             # All unit names
    depends*: Table[string, seq[string]] # Hard dependencies (unit -> units it depends on)
    after*: Table[string, seq[string]]  # Soft ordering (unit -> units it should start after)
    configs*: Table[string, UnitConfig] # Cached unit configs

  StartOrder* = seq[string] # Units in order they should be started

  DependencyError* = object of CatchableError
    ## Error during dependency resolution

proc initDependencyGraph*(): DependencyGraph =
  result.nodes = initHashSet[string]()
  result.depends = initTable[string, seq[string]]()
  result.after = initTable[string, seq[string]]()
  result.configs = initTable[string, UnitConfig]()

proc loadUnitConfig(graph: var DependencyGraph, unitName: string): bool =
  ## Load and cache a unit's config. Returns false if unit doesn't exist.
  if unitName in graph.configs:
    return true

  try:
    let config = parseUnit(configPath, unitName)
    graph.configs[unitName] = config
    graph.nodes.incl(unitName)

    # Store dependencies
    if config.depends.len > 0:
      graph.depends[unitName] = config.depends
    else:
      graph.depends[unitName] = @[]

    # Store ordering
    if config.after.len > 0:
      graph.after[unitName] = config.after
    else:
      graph.after[unitName] = @[]

    return true
  except IOError:
    return false
  except CatchableError:
    return false

proc buildGraph*(units: seq[string]): DependencyGraph =
  ## Build dependency graph for a set of units and all their dependencies
  result = initDependencyGraph()

  var toProcess = units.toHashSet()
  var processed = initHashSet[string]()

  while toProcess.len > 0:
    var unit: string
    for u in toProcess:
      unit = u
      break
    toProcess.excl(unit)

    if unit in processed or isEmptyOrWhitespace(unit):
      continue
    processed.incl(unit)

    # Try to load the unit
    if not result.loadUnitConfig(unit):
      # Unit doesn't exist - might be okay if it's optional
      continue

    # Queue dependencies for processing
    for dep in result.depends.getOrDefault(unit, @[]):
      if dep notin processed:
        toProcess.incl(dep)

    # Also check after units (for complete graph)
    for afterUnit in result.after.getOrDefault(unit, @[]):
      if afterUnit notin processed:
        toProcess.incl(afterUnit)

proc detectCycle(graph: DependencyGraph, start: string,
                 visiting: var HashSet[string],
                 visited: var HashSet[string],
                 path: var seq[string]): seq[string] =
  ## Detect dependency cycle starting from a node. Returns cycle path or empty.
  ## Uses standard DFS coloring: visiting = gray (in progress), visited = black (done)

  if start in visiting:
    # Found a back edge - cycle detected
    let idx = path.find(start)
    if idx >= 0:
      return path[idx .. ^1] & start
    return @[start]

  if start in visited:
    # Already fully processed, no cycle through this node
    return @[]

  if start notin graph.nodes:
    # Node doesn't exist in graph
    return @[]

  visiting.incl(start)
  path.add(start)

  for dep in graph.depends.getOrDefault(start, @[]):
    let cycle = detectCycle(graph, dep, visiting, visited, path)
    if cycle.len > 0:
      return cycle

  discard path.pop()
  visiting.excl(start)
  visited.incl(start)
  return @[]

proc checkForCycles*(graph: DependencyGraph): seq[string] =
  ## Check graph for dependency cycles. Returns cycle path or empty seq.
  var visiting = initHashSet[string]()
  var visited = initHashSet[string]()
  var path: seq[string] = @[]

  for node in graph.nodes:
    if node notin visited:
      let cycle = detectCycle(graph, node, visiting, visited, path)
      if cycle.len > 0:
        return cycle

  return @[]

proc topologicalSort*(graph: DependencyGraph): StartOrder =
  ## Sort units in dependency order (dependencies first)
  ## Considers both `depends` and `after` for ordering
  var inDegree = initTable[string, int]()
  var sorted: seq[string] = @[]

  # Initialize in-degrees
  for node in graph.nodes:
    inDegree[node] = 0

  # Calculate in-degrees based on both depends and after
  for node in graph.nodes:
    # Count how many things this node must come after
    for dep in graph.depends.getOrDefault(node, @[]):
      if dep in graph.nodes:
        inDegree[node] = inDegree.getOrDefault(node, 0) + 1

    for afterUnit in graph.after.getOrDefault(node, @[]):
      if afterUnit in graph.nodes:
        inDegree[node] = inDegree.getOrDefault(node, 0) + 1

  # Build reverse adjacency for efficiency
  var dependents = initTable[string, seq[string]]()
  for node in graph.nodes:
    dependents[node] = @[]

  for node in graph.nodes:
    for dep in graph.depends.getOrDefault(node, @[]):
      if dep in graph.nodes:
        dependents[dep].add(node)
    for afterUnit in graph.after.getOrDefault(node, @[]):
      if afterUnit in graph.nodes:
        dependents[afterUnit].add(node)

  # Kahn's algorithm
  var queue: seq[string] = @[]
  for node, degree in inDegree.pairs:
    if degree == 0:
      queue.add(node)

  while queue.len > 0:
    let node = queue[0]
    queue.delete(0)
    sorted.add(node)

    for dependent in dependents.getOrDefault(node, @[]):
      inDegree[dependent] = inDegree[dependent] - 1
      if inDegree[dependent] == 0:
        queue.add(dependent)

  # If sorted doesn't contain all nodes, there's a cycle
  if sorted.len != graph.nodes.len:
    raise newException(DependencyError, "Dependency cycle detected")

  return sorted

proc getStartOrder*(units: seq[string]): StartOrder =
  ## Get the order to start units (dependencies first)
  ## This is the main entry point for dependency resolution
  let graph = buildGraph(units)

  # Check for cycles
  let cycle = checkForCycles(graph)
  if cycle.len > 0:
    raise newException(DependencyError,
      "Circular dependency detected: " & cycle.join(" -> "))

  return topologicalSort(graph)

proc getMissingDependencies*(unit: string): seq[string] =
  ## Get list of dependencies that are not available for a unit
  result = @[]
  var graph = initDependencyGraph()

  if not graph.loadUnitConfig(unit):
    return @[unit] # Unit itself doesn't exist

  for dep in graph.depends.getOrDefault(unit, @[]):
    if not fileExists(configPath / dep & ".kg"):
      result.add(dep)

proc validateDependencies*(unit: string): tuple[valid: bool, missing: seq[string]] =
  ## Validate that all hard dependencies for a unit exist
  let missing = getMissingDependencies(unit)
  return (valid: missing.len == 0, missing: missing)
