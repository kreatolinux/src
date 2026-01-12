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
import commonPaths
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
        useCacheIfAvailable*: bool
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
    return runFile(pkg: package.name, version: package.version,
            versionString: package.version, release: package.release,
            epoch: package.epoch, deps: package.deps.split("!!k!!"),
            bdeps: package.bdeps.split("!!k!!"), bsdeps: @[])

proc hasCachedBuild(pkg: string, repo: string, root: string): bool =
    ## Check if a package has a cached build tarball available
    try:
        let target = kpkgTarget(root)
        let pkgrf = parseRunfile(repo&"/"&pkg)
        let cachePath = kpkgArchivesDir&"/system/"&target&"/"&pkg&"-"&pkgrf.versionString&".kpkg"
        let exists = fileExists(cachePath)
        debug "dephandler: hasCachedBuild for '"&pkg&"': target="&target&", version="&pkgrf.versionString&", path="&cachePath&", exists="&($exists)
        return exists
    except:
        debug "dephandler: hasCachedBuild for '"&pkg&"' failed with exception"
        return false


### Helper functions for package resolution

proc resolvePackageRepo(pkg: string, chkInstalledDirInstead: bool,
        isInstallDir: bool): repoInfo =
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
        debug "dephandler: packageToRunFile ran, loadPackageMetadata, pkg: '"&name&"' root: '"&root&"'"
        return packageToRunFile(getPackage(name, root))
    else:
        debug "dephandler: parseRunfile ran, loadPackageMetadata, repo: '"&repo&"', pkg: '"&name&"'"
        return parseRunfile(repo&"/"&name)

proc selectDependencyList(pkgrf: runFile, bdeps: bool, useBootstrap: bool): seq[string] =
    ## Select appropriate dependency list based on flags

    if useBootstrap and pkgrf.bsdeps.len > 0:
        return pkgrf.bsdeps
    elif bdeps:
        return pkgrf.bdeps
    else:
        return pkgrf.deps

proc validatePackage(pkg: string, repo: string, root: string): bool =
    ## Validate package exists in repository

    if repo == "":
        err("Package '"&pkg&"' doesn't exist in any configured repository", false)
        return false
    elif repo == "local":
        if not packageExists(pkg, root):
            debug "dephandler: Package '"&pkg&"' doesn't exist in local database at '"&root&"'"
            return false
        return true
    elif not dirExists(repo):
        err("The repository '"&repo&"' doesn't exist at path: "&repo, false)
        return false
    elif not fileExists(repo&"/"&pkg&"/run"):
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

                debug "dephandler: parseRunfile ran, checkVersions"
                deprf = parseRunfile(r&"/"&dSplit[0]).versionString

            let warnName = "Required dependency version for "&dSplit[
                    0]&" not found, upgrading"
            let errName = "Required dependency version for "&dSplit[
                    0]&" not found on repositories, cannot continue"


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

    # Identify root packages by name so we don't skip them if they appear as dependencies
    var rootPkgNames = initHashSet[string]()
    for p in pkgs:
        if not isEmptyOrWhitespace(p) and p notin ignoreDeps:
            let info = resolvePackageRepo(p, chkInstalledDirInstead, isInstallDir)
            rootPkgNames.incl(info.name)

    while toProcess.len > 0:
        let p = toProcess.pop()

        if p in processed or p in ignoreDeps or isEmptyOrWhitespace(p):
            debug "dephandler: Skipping '"&p&"' (processed="&($(p in
                    processed))&", ignoreDeps="&($(p in
                    ignoreDeps))&", empty="&($(isEmptyOrWhitespace(p)))&")"
            continue
        debug "dephandler: Processing package '"&p&"'"
        processed.incl(p)

        # Resolve package info
        let pkgInfo = resolvePackageRepo(p, chkInstalledDirInstead, isInstallDir)
        let pkg = pkgInfo.name
        var repo = pkgInfo.repo

        # Validate package exists
        if not validatePackage(pkg, repo, ctx.root):
            debug "dephandler: Package '"&pkg&"' validation failed (repo: '"&repo&"'), not skipping"
            #continue

        let pkgrf = loadPackageMetadata(pkg, repo, ctx.root)

        # Create resolved package node
        let resolvedPkg = resolvedPackage(
            name: pkg,
            repo: repo,
            metadata: pkgrf
        )

        # Add to graph
        debug "dephandler: Adding node '"&pkg&"' to graph (repo: '"&repo&"')"
        addNode(graph, resolvedPkg)

        # Handle init-specific packages
        if not ctx.ignoreInit and not isEmptyOrWhitespace(ctx.init):
            let initPkg = pkg&"-"&ctx.init
            let initPkgExists = if isInstallDir: dirExists(
                    repo&"/"&initPkg) else: findPkgRepo(initPkg) != ""
            debug "dephandler: Checking init package '"&initPkg&"' for '"&pkg&"' (exists: "&(
                    $initPkgExists)&")"
            if initPkgExists:
                let initPkgToAdd = if isInstallDir: repo&"/"&initPkg else: initPkg
                if initPkgToAdd notin processed and initPkgToAdd notin toProcess:
                    debug "dephandler: Adding init package '"&initPkgToAdd&"' to processing queue"
                    toProcess.add(initPkgToAdd)
                    addEdge(graph, initPkg, pkg) # Edge from dependency to dependent
        
        # Process build dependencies first if this is a build
        # Use bootstrap deps if in bootstrap mode and they exist, otherwise use regular build deps
        # Skip build deps if useCacheIfAvailable is true and cached build exists
        let buildDeps = selectDependencyList(pkgrf, true, ctx.useBootstrap)
        #let skipBuildDeps = ctx.useCacheIfAvailable and repo != "local" and hasCachedBuild(pkg, repo, ctx.root)
        #if skipBuildDeps:
        #    debug "dephandler: Package '"&pkg&"' has cached build, skipping build dependencies"

        if ctx.isBuild and not isEmptyOrWhitespace(buildDeps.join()): #and not skipBuildDeps:
            debug "dephandler: Processing "&(
                    $buildDeps.len)&" build dependencies for '"&pkg&"': "&buildDeps.join(", ")
            for bdep in buildDeps:
                if isEmptyOrWhitespace(bdep) or bdep in ignoreDeps:
                    debug "dephandler: Skipping build dep '"&bdep&"' (empty or in ignoreDeps)"
                    continue

                # Check version requirements
                let chkVer = checkVersions(ctx.root, bdep, repo)
                let depName = chkVer[1]

                # Skip if already installed and not forcing
                # Don't skip if the dependency is one of the root packages we are explicitly processing
                if packageExists(depName, ctx.root) and chkVer[0] !=
                        "upgrade" and not ctx.forceInstallAll and depName notin rootPkgNames:
                    debug "dephandler: Package '"&depName&"' already installed, skipping"
                    continue

                # Update repo for dependency
                if not chkInstalledDirInstead:
                    let depRepo = findPkgRepo(depName)
                    debug "dephandler: findPkgRepo('"&depName&"') returned '"&depRepo&"' for build dep"
                    if depRepo != "":
                        repo = depRepo
                    else:
                        debug "dephandler: Build dep '"&depName&"' not found in any repository!"

                # Skip self-dependency if the package is already installed
                # (e.g., gmake requiring gmake to build - use the installed gmake)
                if depName == pkg and packageExists(depName, ctx.root):
                    debug "dephandler: Skipping self-dependency '"&depName&"' (already installed)"
                    continue

                # Add edge and schedule for processing (edge from dependency to dependent)
                debug "dephandler: Adding edge '"&depName&"' -> '"&pkg&"' for build dep"
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
            debug "dephandler: Processing "&(
                    $runtimeDeps.len)&" runtime dependencies for '"&pkg&"': "&runtimeDeps.join(", ")
            for dep in runtimeDeps:
                if isEmptyOrWhitespace(dep) or dep in ignoreDeps:
                    debug "dephandler: Skipping runtime dep '"&dep&"' (empty or in ignoreDeps)"
                    continue

                # Check version requirements
                let chkVer = checkVersions(ctx.root, dep, repo)
                let depName = chkVer[1]

                # Skip if already installed and not forcing
                # Don't skip if the dependency is one of the root packages we are explicitly processing
                if packageExists(depName, ctx.root) and chkVer[0] !=
                        "upgrade" and not ctx.forceInstallAll and depName notin rootPkgNames:
                    debug "Package '"&depName&"' already installed, skipping"
                    continue

                # Update repo for dependency
                if not chkInstalledDirInstead:
                    let depRepo = findPkgRepo(depName)
                    if depRepo != "":
                        repo = depRepo

                # Skip self-dependency if the package is already installed
                # (e.g., gmake requiring gmake to build - use the installed gmake)
                if depName == pkg and packageExists(depName, ctx.root):
                    debug "dephandler: Skipping self-dependency '"&depName&"' (already installed)"
                    continue

                # Add edge and schedule for processing (edge from dependency to dependent)
                addEdge(graph, depName, pkg)
                # Add to processing queue if not already there
                # When forceInstallAll=true, we may re-add packages that were processed but skipped due to being installed
                # When isInstallDir=true, add full path so dependency resolution works correctly
                let depToAdd = if isInstallDir: repo&"/"&depName else: depName
                if depToAdd notin toProcess:
                    if ctx.forceInstallAll or depToAdd notin processed:
                        debug "dephandler: Adding runtime dep '"&depToAdd&"' to processing queue"
                        toProcess.add(depToAdd)
                    else:
                        debug "dephandler: Runtime dep '"&depToAdd&"' already processed and not forcing, skipping"
                else:
                    debug "dephandler: Runtime dep '"&depToAdd&"' already in processing queue"

    debug "dephandler: Finished building dependency graph with "&(
            $graph.nodes.len)&" nodes"
    return graph

proc topologicalSort(graph: dependencyGraph,
        ignoreCircularDeps: bool = false): seq[string] =
    ## Perform topological sort using DFS to determine installation order
    ## Returns packages in order where dependencies come before dependents
    ##
    ## Graph structure: edges go FROM dependency TO dependent
    ## Example: graph.edges["openssl"] = ["python"] means python depends on openssl
    ##
    ## If a cycle is detected and ignoreCircularDeps is false, this proc will
    ## error out with a message instructing the packager to use bootstrap
    ## dependencies (bsdeps) to break the cycle.
    ##
    ## If ignoreCircularDeps is true, cycles are warned about but processing
    ## continues (useful for query commands like `kpkg get deps`).

    var visited = initTable[string, bool]()
    var visiting = initTable[string, bool]()
    var sortResult: seq[string] = @[]
    var visitStack: seq[string] = @[] # Track the current DFS path for cycle reporting
    var cycleDetected = false
    var cyclePath: seq[string] = @[]

    proc visit(node: string) =
        # Stop processing if cycle already detected
        if cycleDetected:
            return

        # Check for cycles - if we're visiting a node that's already in progress,
        # we've found a cycle
        if visiting.getOrDefault(node, false):
            # Extract the cycle from visitStack
            let cycleStart = visitStack.find(node)
            if cycleStart >= 0:
                cyclePath = visitStack[cycleStart .. ^1]
                cyclePath.add(node) # Close the cycle
            else:
                cyclePath = @[node]
            cycleDetected = true
            return

        # Skip if already processed
        if visited.getOrDefault(node, false):
            return

        # Mark as currently being visited (for cycle detection)
        visiting[node] = true
        visitStack.add(node)

        # Recursively visit all nodes this node points to (dependents)
        # We visit dependents first so they get added to result first
        if graph.edges.hasKey(node):
            for dependent in graph.edges[node]:
                visit(dependent)
                if cycleDetected:
                    return

        # Pop from stack and mark as fully visited
        visitStack.setLen(visitStack.len - 1)
        visiting[node] = false
        visited[node] = true

        # Add to result AFTER visiting all dependents (post-order DFS)
        # This means dependents are earlier in the list
        sortResult.add(node)

    # Visit all nodes (handles disconnected components)
    for node in graph.nodes.keys:
        if not visited.getOrDefault(node, false):
            visit(node)
            if cycleDetected:
                break

    # Handle cycle detection result
    if cycleDetected:
        debug "which came first, the chicken or the egg?"
        let cycleMsg = "circular dependency detected: " & cyclePath.join(
                " -> ") &
            ". Use bootstrap dependencies (bsdeps) to break the cycle."
        if ignoreCircularDeps:
            warn(cycleMsg)
        else:
            err(cycleMsg)

    # Reverse: since we added dependents before dependencies in post-order,
    # reversing gives us dependencies before dependents
    reverse(sortResult)

    return sortResult

proc flattenDependencyOrder*(graph: dependencyGraph,
        ignoreCircularDeps: bool = false): seq[string] =
    ## Convert graph to installation order (dependencies first)

    # Topological sort now gives us the correct order directly
    # (dependencies before dependents) since edges go from dependency to dependent
    let sorted = topologicalSort(graph, ignoreCircularDeps)
    debug "dephandler: Topological sort result ("&(
            $sorted.len)&" packages): "&sorted.join(", ")
    return sorted

proc generateMermaidChart*(graph: dependencyGraph, rootPackages: seq[
        string]): string =
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
            output &= "    style " & nodeId & " fill:#4a9eff,stroke:#2d7dd2,stroke-width:3px,color:#fff\n"
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
                forceInstallAll = false, chkInstalledDirInstead = false,
                        isInstallDir = false, ignoreInit = false,
                        useBootstrap = false, ignoreCircularDeps = false,
                        useCacheIfAvailable = false): seq[string] =
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
        useCacheIfAvailable: useCacheIfAvailable,
        init: init
    )

    # Build the dependency graph
    let graph = buildDependencyGraph(
        pkgs, ctx, ignoreDeps,
        chkInstalledDirInstead, isInstallDir, prevPkgName
    )

    # Flatten to installation order
    let ordered = flattenDependencyOrder(graph, ctx.ignoreCircularDeps)

    # Filter out root packages (the packages being built/installed) and empty strings
    # We only want the dependencies, not the target packages themselves
    let rootPkgSet = pkgs.toHashSet()
    debug "dephandler: Root packages to filter out: "&pkgs.join(", ")
    let filtered = ordered.filterIt(it.len != 0 and it notin rootPkgSet)
    debug "dephandler: After filtering root packages: "&filtered.join(", ")

    # Deduplicate and return
    let finalResult = deduplicate(filtered)
    debug "dephandler: Final dependency list ("&(
            $finalResult.len)&" packages): "&finalResult.join(", ")
    return finalResult

proc dephandlerWithGraph*(pkgs: seq[string], ignoreDeps = @["  "],
        isBuild = false, root: string, prevPkgName = "",
                forceInstallAll = false, chkInstalledDirInstead = false,
                        isInstallDir = false, ignoreInit = false,
                        useBootstrap = false, ignoreCircularDeps = false,
                        useCacheIfAvailable = false): (seq[string],
                        dependencyGraph) =
    ## Takes packages and returns what to install in correct dependency order PLUS the dependency graph
    ## This allows reusing the graph structure instead of recalculating dependencies

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
        useCacheIfAvailable: useCacheIfAvailable,
        init: init
    )

    # Build the dependency graph
    let graph = buildDependencyGraph(
        pkgs, ctx, ignoreDeps,
        chkInstalledDirInstead, isInstallDir, prevPkgName
    )

    # Flatten to installation order
    let ordered = flattenDependencyOrder(graph, ctx.ignoreCircularDeps)

    # Filter out root packages (the packages being built/installed) and empty strings
    let rootPkgSet = pkgs.toHashSet()
    debug "dephandler: Root packages to filter out: "&pkgs.join(", ")
    let filtered = ordered.filterIt(it.len != 0 and it notin rootPkgSet)
    debug "dephandler: After filtering root packages: "&filtered.join(", ")

    # Return both the dependency list and the graph
    let finalResult = deduplicate(filtered)
    debug "dephandler: Final dependency list ("&(
            $finalResult.len)&" packages): "&finalResult.join(", ")
    return (finalResult, graph)

proc collectRuntimeDepsFromGraph*(pkgs: seq[string], graph: dependencyGraph,
        visited: var HashSet[string]): seq[string] =
    ## Recursively collect all runtime dependencies from the graph (exported for reuse)
    result = @[]

    for pkg in pkgs:
        if pkg in visited or pkg notin graph.nodes:
            continue
        visited.incl(pkg)
        result.add(pkg)

        # Recursively get runtime deps
        let runtimeDeps = graph.nodes[pkg].metadata.deps
        let transitiveDeps = collectRuntimeDepsFromGraph(runtimeDeps, graph, visited)
        result = result & transitiveDeps

proc getSandboxDepsFromGraph*(pkg: string, graph: dependencyGraph,
        bootstrap: bool, root: string, forceInstallAll: bool,
        isInstallDir: bool, ignoreInit: bool): seq[string] =
    ## Extract sandbox dependencies for a package from the dependency graph
    ## This avoids recalculating dependencies that were already resolved

    if pkg notin graph.nodes:
        debug "dephandler: Package '"&pkg&"' not found in dependency graph"
        return @[]

    let node = graph.nodes[pkg]
    let isBootstrapBuild = bootstrap and node.metadata.bsdeps.len > 0
    let baseDeps = if isBootstrapBuild: node.metadata.bsdeps else: node.metadata.bdeps

    var sandboxDeps: seq[string] = baseDeps
    var visited = initHashSet[string]()

    # For bootstrap builds: only the bootstrap deps and their transitive runtime deps
    # For regular builds: build deps + their transitive runtime deps + package's transitive runtime deps
    if isBootstrapBuild:
        # Bootstrap: get all transitive runtime deps of the bootstrap deps themselves
        let transitiveDeps = collectRuntimeDepsFromGraph(baseDeps, graph, visited)
        sandboxDeps = sandboxDeps & transitiveDeps
    else:
        # Regular build: include transitive runtime deps of build dependencies
        # (needed when build tools use other tools that have runtime deps)
        let buildDepTransitiveDeps = collectRuntimeDepsFromGraph(baseDeps,
                graph, visited)
        sandboxDeps = sandboxDeps & buildDepTransitiveDeps
        # Also include all transitive runtime deps of the package being built
        let transitiveDeps = collectRuntimeDepsFromGraph(@[pkg], graph, visited)
        # Filter out the package itself from its transitive deps
        sandboxDeps = sandboxDeps & transitiveDeps.filterIt(it != pkg)

    # Add optional dependencies if they're installed
    for optDep in node.metadata.optdeps:
        let optDepName = optDep.split(":")[0]
        if packageExists(optDepName, root):
            sandboxDeps.add(optDepName)

    return deduplicate(sandboxDeps)
