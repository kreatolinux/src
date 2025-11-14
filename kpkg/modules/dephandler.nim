# dephandler v3
import os
import sets
import config
import tables
import sqlite
import logger
import sequtils
import strutils
import runparser
import commonTasks
import algorithm

type
    repoInfo = tuple[repo: string, name: string, version: string]
    
    dependencyContext* = object
        root*: string
        isBuild*: bool
        useBootstrap*: bool
        ignoreInit*: bool
        ignoreCircularDeps*: bool
        forceInstallAll*: bool
        init*: string
    
    resolvedPackage* = object
        name*: string
        repo*: string
        metadata*: runFile
    
    dependencyGraph* = object
        nodes*: Table[string, resolvedPackage]
        edges*: Table[string, seq[string]]

proc packageToRunFile(package: Package): runFile =
    ## Converts package to runFile. Not all variables are available.
    return runFile(pkg: package.name, version: package.version, versionString: package.version, release: package.release, epoch: package.epoch, deps: package.deps.split("!!k!!"), bdeps: package.bdeps.split("!!k!!"), bsdeps: @[])


### Helper functions for package resolution

proc resolvePackageRepo(pkg: string, chkInstalledDirInstead: bool, isInstallDir: bool): repoInfo =
    ## Resolve package name and repository from specifier
    
    var name = pkg
    var repo: string
    var version = ""
    
    if isInstallDir:
        repo = absolutePath(pkg).parentDir()
        name = lastPathPart(pkg)
    elif chkInstalledDirInstead:
        repo = "local"
        name = pkg
    else:
        let pkgSplit = parsePkgInfo(pkg)
        name = pkgSplit.name
        repo = pkgSplit.repo
        version = pkgSplit.version
    
    return (repo: repo, name: name, version: version)

proc loadPackageMetadata(name: string, repo: string, root: string): runFile =
    ## Load package metadata from repository or installed database
    
    if repo == "local":
        debug "packageToRunFile ran, loadPackageMetadata, pkg: '"&name&"' root: '"&root&"'"
        return packageToRunFile(getPackage(name, root))
    else:
        debug "parseRunfile ran, loadPackageMetadata, repo: '"&repo&"', pkg: '"&name&"'"
        return parseRunfile(repo&"/"&name)

proc selectDependencyList(pkgrf: runFile, bdeps: bool, useBootstrap: bool): seq[string] =
    ## Select appropriate dependency list based on flags
    
    if useBootstrap and pkgrf.bsdeps.len > 0:
        return pkgrf.bsdeps
    elif bdeps:
        return pkgrf.bdeps
    else:
        return pkgrf.deps

proc validatePackage(pkg: string, repo: string): bool =
    ## Validate package exists in repository
    
    if repo == "":
        err("Package '"&pkg&"' doesn't exist in any configured repository", false)
        return false
    elif not dirExists(repo) and repo != "local":
        err("The repository '"&repo&"' doesn't exist at path: "&repo, false)
        return false
    elif not fileExists(repo&"/"&pkg&"/run") and repo != "local":
        err("The package '"&pkg&"' doesn't exist in repository "&repo&" (expected: "&repo&"/"&pkg&"/run)", false)
        return false
    
    return true

proc checkVersions(root: string, dependency: string, repo: string, split = @[
        "<=", ">=", "<", ">", "="]): seq[string] =
    ## Check version requirements on dependency

    for i in split:
        if i in dependency:

            let dSplit = dependency.split(i)
            var deprf: string

            if packageExists(dSplit[0], root):
                deprf = getPackage(dSplit[0], root).version
            else:
                var r = repo

                if repo == "local":
                    r = findPkgRepo(r)
                
                debug "parseRunfile ran, checkVersions"
                deprf = parseRunfile(r&"/"&dSplit[0]).versionString

            let warnName = "Required dependency version for "&dSplit[0]&" not found, upgrading"
            let errName = "Required dependency version for "&dSplit[0]&" not found on repositories, cannot continue"


            case i:
                of "<=":
                    if not (deprf <= dSplit[1]):
                        if packageExists(dSplit[0], root):
                            warn(warnName)
                            return @["upgrade", dSplit[0]]
                        else:
                            err(errName, false)
                of ">=":
                    if not (deprf >= dSplit[1]):
                        if packageExists(dSplit[0], root):
                            warn(warnName)
                            return @["upgrade", dSplit[0]]
                        else:
                            err(errName, false)
                of "<":
                    if not (deprf < dSplit[1]):
                        if packageExists(dSplit[0], root):
                            warn(warnName)
                            return @["upgrade", dSplit[0]]
                        else:
                            err(errName, false)
                of ">":
                    if not (deprf > dSplit[1]):
                        if packageExists(dSplit[0], root):
                            warn(warnName)
                            return @["upgrade", dSplit[0]]
                        else:
                            err(errName, false)
                of "=":
                    if deprf != dSplit[1]:
                        if packageExists(dSplit[0], root):
                            warn(warnName)
                            return @["upgrade", dSplit[0]]
                        else:
                            err(errName, false)

            return @["noupgrade", dSplit[0]]

    return @["noupgrade", dependency]


proc initDependencyGraph*(): dependencyGraph =
    ## Initialize an empty dependency graph
    result.nodes = initTable[string, resolvedPackage]()
    result.edges = initTable[string, seq[string]]()

proc addNode(graph: var dependencyGraph, pkg: resolvedPackage) =
    ## Add a package node to the graph
    graph.nodes[pkg.name] = pkg
    if not graph.edges.hasKey(pkg.name):
        graph.edges[pkg.name] = @[]

proc addEdge(graph: var dependencyGraph, fromPkg: string, toPkg: string) =
    ## Add a dependency edge from one package to another
    if not graph.edges.hasKey(fromPkg):
        graph.edges[fromPkg] = @[]
    if toPkg notin graph.edges[fromPkg]:
        graph.edges[fromPkg].add(toPkg)

proc buildDependencyGraph*(pkgs: seq[string], ctx: dependencyContext, 
                          ignoreDeps: seq[string] = @["  "],
                          chkInstalledDirInstead = false,
                          isInstallDir = false,
                          prevPkgName = ""): dependencyGraph =
    ## Build dependency graph by traversing all dependencies
    
    var graph = initDependencyGraph()
    var toProcess = pkgs
    var processed: HashSet[string]
    
    while toProcess.len > 0:
        let p = toProcess.pop()
        
        if p in processed or p in ignoreDeps or isEmptyOrWhitespace(p):
            continue
        processed.incl(p)
        
        # Resolve package info
        let pkgInfo = resolvePackageRepo(p, chkInstalledDirInstead, isInstallDir)
        let pkg = pkgInfo.name
        var repo = pkgInfo.repo
        
        # Validate package exists
        if not validatePackage(pkg, repo):
            continue
        
        let pkgrf = loadPackageMetadata(pkg, repo, ctx.root)
        
        # Create resolved package node
        let resolvedPkg = resolvedPackage(
            name: pkg,
            repo: repo,
            metadata: pkgrf
        )
        
        # Add to graph
        addNode(graph, resolvedPkg)
        
        # Handle init-specific packages
        if not ctx.ignoreInit and not isEmptyOrWhitespace(ctx.init):
            let initPkg = pkg&"-"&ctx.init
            let initPkgExists = if isInstallDir: dirExists(repo&"/"&initPkg) else: findPkgRepo(initPkg) != ""
            if initPkgExists:
                let initPkgToAdd = if isInstallDir: repo&"/"&initPkg else: initPkg
                if initPkgToAdd notin processed and initPkgToAdd notin toProcess:
                    toProcess.add(initPkgToAdd)
                    addEdge(graph, initPkg, pkg)  # Edge from dependency to dependent
        
        # Process build dependencies first if this is a build
        if ctx.isBuild and not isEmptyOrWhitespace(pkgrf.bdeps.join()):
            for bdep in pkgrf.bdeps:
                if isEmptyOrWhitespace(bdep) or bdep in ignoreDeps:
                    continue
                
                # Check for circular dependencies
                if prevPkgName == bdep:
                    if ctx.ignoreCircularDeps:
                        debug "Ignoring circular dependency: "&prevPkgName&" -> "&bdep
                        continue
                    elif not packageExists(bdep, "/"):
                        if ctx.useBootstrap:
                            debug "Bootstrap mode: allowing circular dependency"
                            continue
                        else:
                            err("circular dependency detected for '"&bdep&"'", false)
                            continue
                    else:
                        debug "Circular dependency found but continuing: "&prevPkgName&" -> "&bdep
                        continue
                
                # Check version requirements
                let chkVer = checkVersions(ctx.root, bdep, repo)
                let depName = chkVer[1]
                
                # Skip if already installed and not forcing
                if packageExists(depName, ctx.root) and chkVer[0] != "upgrade" and not ctx.forceInstallAll:
                    debug "Package '"&depName&"' already installed, skipping"
                    continue
                
                # Update repo for dependency
                if not chkInstalledDirInstead:
                    let depRepo = findPkgRepo(depName)
                    if depRepo != "":
                        repo = depRepo
                
                # Add edge and schedule for processing (edge from dependency to dependent)
                addEdge(graph, depName, pkg)
                # Add to processing queue if not already there
                # When forceInstallAll=true, we may re-add packages that were processed but skipped due to being installed
                # When isInstallDir=true, add full path so dependency resolution works correctly
                let depToAdd = if isInstallDir: repo&"/"&depName else: depName
                if depToAdd notin toProcess:
                    if ctx.forceInstallAll or depToAdd notin processed:
                        toProcess.add(depToAdd)
        
        # Process runtime dependencies (use bootstrap if requested)
        let runtimeDeps = selectDependencyList(pkgrf, false, ctx.useBootstrap)
        
        if not isEmptyOrWhitespace(runtimeDeps.join()):
            for dep in runtimeDeps:
                if isEmptyOrWhitespace(dep) or dep in ignoreDeps:
                    continue
                
                # Check for circular dependencies
                if prevPkgName == dep:
                    if ctx.ignoreCircularDeps:
                        debug "Ignoring circular dependency: "&prevPkgName&" -> "&dep
                        continue
                    elif ctx.isBuild and not packageExists(dep, "/"):
                        if ctx.useBootstrap:
                            debug "Bootstrap mode: allowing circular dependency"
                            continue
                        else:
                            err("circular dependency detected for '"&dep&"'", false)
                            continue
                    else:
                        debug "Circular dependency found but continuing: "&prevPkgName&" -> "&dep
                        continue
                
                # Check version requirements
                let chkVer = checkVersions(ctx.root, dep, repo)
                let depName = chkVer[1]
                
                # Skip if already installed and not forcing
                if packageExists(depName, ctx.root) and chkVer[0] != "upgrade" and not ctx.forceInstallAll:
                    debug "Package '"&depName&"' already installed, skipping"
                    continue
                
                # Update repo for dependency
                if not chkInstalledDirInstead:
                    let depRepo = findPkgRepo(depName)
                    if depRepo != "":
                        repo = depRepo
                
                # Add edge and schedule for processing (edge from dependency to dependent)
                addEdge(graph, depName, pkg)
                # Add to processing queue if not already there
                # When forceInstallAll=true, we may re-add packages that were processed but skipped due to being installed
                # When isInstallDir=true, add full path so dependency resolution works correctly
                let depToAdd = if isInstallDir: repo&"/"&depName else: depName
                if depToAdd notin toProcess:
                    if ctx.forceInstallAll or depToAdd notin processed:
                        toProcess.add(depToAdd)
    
    return graph

proc topologicalSort(graph: dependencyGraph): seq[string] =
    ## Perform topological sort using DFS to determine installation order
    ## Returns packages in order where dependencies come before dependents
    ## 
    ## Graph structure: edges go FROM dependency TO dependent
    ## Example: graph.edges["openssl"] = ["python"] means python depends on openssl
    
    var visited = initTable[string, bool]()
    var visiting = initTable[string, bool]()
    var sortResult: seq[string] = @[]
    
    proc visit(node: string) =
        # Check for cycles
        if visiting.getOrDefault(node, false):
            debug "Warning: Cycle detected involving package: " & node
            return
        
        # Skip if already processed
        if visited.getOrDefault(node, false):
            return
        
        # Mark as currently being visited (for cycle detection)
        visiting[node] = true
        
        # Recursively visit all nodes this node points to (dependents)
        # We visit dependents first so they get added to result first
        if graph.edges.hasKey(node):
            for dependent in graph.edges[node]:
                visit(dependent)
        
        # Mark as fully visited
        visiting[node] = false
        visited[node] = true
        
        # Add to result AFTER visiting all dependents (post-order DFS)
        # This means dependents are earlier in the list
        sortResult.add(node)
    
    # Visit all nodes (handles disconnected components)
    for node in graph.nodes.keys:
        if not visited.getOrDefault(node, false):
            visit(node)
    
    # Reverse: since we added dependents before dependencies in post-order,
    # reversing gives us dependencies before dependents
    reverse(sortResult)
    
    return sortResult

proc flattenDependencyOrder*(graph: dependencyGraph): seq[string] =
    ## Convert graph to installation order (dependencies first)
    
    # Topological sort now gives us the correct order directly
    # (dependencies before dependents) since edges go from dependency to dependent
    return topologicalSort(graph)

proc generateMermaidChart*(graph: dependencyGraph, rootPackages: seq[string]): string =
    ## Generate Mermaid flowchart from dependency graph
    
    var output = "graph TD\n"
    var nodeIds = initTable[string, string]()
    var nodeCounter = 0
    
    # Generate unique IDs for each package node
    for node in graph.nodes.keys:
        let nodeId = "N" & $nodeCounter
        nodeIds[node] = nodeId
        nodeCounter += 1
    
    # Create nodes with labels
    for node, pkg in graph.nodes.pairs:
        let nodeId = nodeIds[node]
        let label = node
        
        # Highlight root packages differently
        if node in rootPackages:
            output &= "    " & nodeId & "[\"" & label & "\"]\n"
            output &= "    style " & nodeId & " fill:#ff9,stroke:#333,stroke-width:3px\n"
        else:
            output &= "    " & nodeId & "[\"" & label & "\"]\n"
    
    # Create edges (dependency relationships)
    for fromNode, toNodes in graph.edges.pairs:
        if nodeIds.hasKey(fromNode):
            let fromId = nodeIds[fromNode]
            for toNode in toNodes:
                if nodeIds.hasKey(toNode):
                    let toId = nodeIds[toNode]
                    output &= "    " & fromId & " --> " & toId & "\n"
    
    return output


proc dephandler*(pkgs: seq[string], ignoreDeps = @["  "],
        isBuild = false, root: string, prevPkgName = "",
                forceInstallAll = false, chkInstalledDirInstead = false, isInstallDir = false, ignoreInit = false, useBootstrap = false, ignoreCircularDeps = false): seq[string] =
    ## Takes packages and returns what to install in correct dependency order
    ## When isBuild = true, returns both build dependencies and runtime dependencies in correct order
    
    # Build dependency context
    var init = ""
    if not ignoreInit:
        init = getInit(root)

    let ctx = dependencyContext(
        root: root,
        isBuild: isBuild,
        useBootstrap: useBootstrap,
        ignoreInit: ignoreInit,
        ignoreCircularDeps: ignoreCircularDeps,
        forceInstallAll: forceInstallAll,
        init: init
    )
    
    # Build the dependency graph
    let graph = buildDependencyGraph(
        pkgs, ctx, ignoreDeps, 
        chkInstalledDirInstead, isInstallDir, prevPkgName
    )
    
    # Flatten to installation order
    let ordered = flattenDependencyOrder(graph)
    
    # Filter out root packages (the packages being built/installed) and empty strings
    # We only want the dependencies, not the target packages themselves
    let rootPkgSet = pkgs.toHashSet()
    let filtered = ordered.filterIt(it.len != 0 and it notin rootPkgSet)
    
    # Deduplicate and return
    return deduplicate(filtered)
