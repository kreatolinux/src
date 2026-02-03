## Main entry point for run3 module (kpkg integration)
## Provides a unified interface for parsing and executing run3 runfiles
## Uses Kongue as the underlying scripting language with kpkg-specific extensions

import os
import parsecfg
import sequtils
import strutils
import tables

# Import Kongue modules
import ../../../kongue/ast
import ../../../kongue/lexer
import ../../../kongue/parser
import ../../../kongue/variables
import ../../../kongue/utils as kongueUtils
import ../../../kongue/context
import ../../../kongue/builtins
import ../../../kongue/executor

# Import kpkg-specific modules
import macros as run3macros
import ../processes
import ../commonPaths
import ../../../common/logging

# Re-export kongue modules for backward compatibility (but not utils to avoid conflict)
export ast, lexer, parser, variables, context, builtins, executor, run3macros

type
    Run3Context* = ref object of ExecutionContext
        ## Extended execution context with kpkg-specific fields
        passthrough*: bool   ## Passthrough execution (no sandbox)
        sandboxPath*: string ## Sandbox root path
        remount*: bool       ## Remount sandbox
        asRoot*: bool        ## Run as root in sandbox (for postinstall)

    Run3File* = object
        ## Represents a parsed and ready-to-execute run3 file
        parsed*: ParsedScript
        path*: string
        isParsed*: bool

proc initRun3Context*(destDir: string = "", srcDir: string = "",
        buildRoot: string = "", packageName: string = ""): Run3Context =
    ## Initialize a new Run3 execution context with kpkg-specific defaults
    result = Run3Context()
    result.variables = initTable[string, string]()
    result.listVariables = initTable[string, seq[string]]()
    result.localVars = initTable[string, string]()
    result.envVars = initTable[string, string]()
    result.customFuncs = initTable[string, seq[AstNode]]()
    # Use srcDir for currentDir if provided (supports autocd from buildcmd)
    if srcDir != "":
        result.currentDir = srcDir
    else:
        result.currentDir = getCurrentDir()
    result.previousDir = result.currentDir
    result.destDir = destDir
    result.srcDir = srcDir
    result.buildRoot = buildRoot
    result.packageName = packageName
    result.silent = false
    # kpkg-specific fields
    result.passthrough = false
    result.sandboxPath = kpkgMergedPath
    result.remount = false
    result.asRoot = false

    # Set up kpkg execution hook for sandboxed execution
    result.execHook = proc(ctx: ExecutionContext, command: string,
            silent: bool): tuple[output: string, exitCode: int] =
        let run3ctx = Run3Context(ctx)
        logging.debug "run3 execHook: sandboxPath=" & run3ctx.sandboxPath &
                ", passthrough=" &
            $run3ctx.passthrough & ", asRoot=" & $run3ctx.asRoot
        return execEnv(command, "none", run3ctx.passthrough, silent,
                run3ctx.sandboxPath, run3ctx.remount, run3ctx.asRoot)

    # Set up macro hook for kpkg macros
    result.macroHook = proc(ctx: ExecutionContext, name: string, args: seq[string]): int =
        return run3macros.executeMacro(ctx, name, args)

# Wire up Kongue logging to kpkg logging
kongueUtils.debugProc = proc(msg: string) = logging.debug(msg)
kongueUtils.warnProc = proc(msg: string) = logging.warn(msg)
kongueUtils.errorProc = proc(msg: string) = logging.error(msg)

proc parseRun3*(path: string): Run3File =
    ## Parse a run3 file from a package directory
    ## Expects path to be the package directory containing run3 file
    logging.debug "parseRun3: starting for path '"&path&"'"
    result.path = path
    result.isParsed = true
    var run3Path = path / "run3"

    if not fileExists(run3Path):
        if fileExists(path / "run"):
            run3Path = path / "run"
        else:
            raise newException(IOError, "run3 file not found at: " & run3Path)

    logging.debug "parseRun3: calling parseFile for '"&run3Path&"'"
    result.parsed = parseFile(run3Path)
    logging.debug "parseRun3: parseFile completed"

proc getVariableRaw(rf: Run3File, name: string): string =
    ## Get a raw variable value from the parsed runfile (no substitution)
    ## Internal use only - use getVariable for public API
    for varNode in rf.parsed.variables:
        case varNode.kind
        of nkVariable:
            if varNode.varName == name:
                return varNode.varValue
        else:
            discard
    return ""

proc getListVariableRaw(rf: Run3File, name: string): seq[string] =
    ## Get a raw list variable value from the parsed runfile (no substitution)
    ## Internal use only - use getListVariable for public API
    for varNode in rf.parsed.variables:
        case varNode.kind
        of nkListVariable:
            if varNode.listName == name:
                return varNode.listItems
        else:
            discard
    return @[]

proc getAllVariablesRaw(rf: Run3File): Table[string, VarValue] =
    ## Get all raw variables as a table (no substitution)
    ## Internal use only
    result = initTable[string, VarValue]()
    for varNode in rf.parsed.variables:
        case varNode.kind
        of nkVariable:
            result[varNode.varName] = newStringValue(varNode.varValue)
        of nkListVariable:
            result[varNode.listName] = newListValue(varNode.listItems)
        else:
            discard

proc resolveManipulationWithTable(vars: Table[string, VarValue],
        expr: string): string =
    ## Resolve a complex variable manipulation expression using a variables table
    ## expr is the content inside ${...}
    ## Supports interleaved methods and indexing: ${version.split('.')[0:2].join('.')}
    let tokens = tokenize(expr)
    var p = 0

    proc peek(): Token =
        if p < tokens.len: tokens[p] else: Token(kind: tkEof)

    proc advance(): Token =
        result = peek()
        p += 1

    # Parse base variable name
    var val: VarValue
    var iterations = 0

    let varName = advance().value
    if vars.hasKey(varName):
        val = vars[varName]
    else:
        let upperName = varName.toUpperAscii()
        if vars.hasKey(upperName):
            val = vars[upperName]
        else:
            val = newStringValue("")

    # Parse and apply operations (methods and indexing interleaved)
    while peek().kind == tkDot or peek().kind == tkLBracket:
        iterations += 1
        if iterations > kongueUtils.maxIterations:
            break

        if peek().kind == tkDot:
            discard advance() # .
            let methodName = peek().value
            discard advance()

            var args: seq[string] = @[]
            if peek().kind == tkLParen:
                discard advance() # (
                while peek().kind != tkRParen and peek().kind != tkEof:
                    iterations += 1
                    if iterations > kongueUtils.maxIterations:
                        break
                    if peek().kind == tkString or peek().kind == tkIdentifier or
                            peek().kind == tkNumber:
                        args.add(advance().value)
                    elif peek().kind == tkComma:
                        discard advance()
                    else:
                        discard advance()
                discard advance() # )

            try:
                val = applyMethod(val, methodName, args)
            except ValueError:
                return ""

        elif peek().kind == tkLBracket:
            discard advance() # [
            var indexExpr = ""
            while peek().kind != tkRBracket and peek().kind != tkEof:
                iterations += 1
                if iterations > kongueUtils.maxIterations:
                    break
                indexExpr.add(advance().value)
            discard advance() # ]

            try:
                val = applyIndex(val, indexExpr)
            except ValueError:
                return ""

    return val.toString()

proc substituteVariablesWithTable(rf: Run3File, vars: Table[string, VarValue],
        value: string): string =
    ## Core variable substitution logic using a provided variables table
    ## Handles complex ${...} expressions and simple $variable references
    result = value

    # First, handle complex ${...} expressions that contain method calls or indexing
    var i = 0
    while i < result.len:
        if i < result.len - 1 and result[i] == '$' and result[i+1] == '{':
            # Find the closing }
            var j = i + 2
            var braceCount = 1
            while j < result.len and braceCount > 0:
                if result[j] == '{':
                    braceCount += 1
                elif result[j] == '}':
                    braceCount -= 1
                j += 1

            if braceCount == 0:
                let varExpr = result[i+2..<j-1]
                # Check if it contains method calls or indexing
                if '.' in varExpr or '[' in varExpr:
                    let resolvedValue = resolveManipulationWithTable(vars, varExpr)
                    result = result[0..<i] & resolvedValue & result[j..^1]
                    i += resolvedValue.len
                else:
                    # Simple variable reference, handle below
                    i += 1
            else:
                i += 1
        else:
            i += 1

    # Replace ${variable} style references (simple ones remaining)
    for varName, varValue in vars:
        let valStr = varValue.toString()
        result = result.replace("${" & varName & "}", valStr)
        result = result.replace("${" & varName.toUpperAscii() & "}", valStr)

    # Replace $variable style references (case variations)
    for varName, varValue in vars:
        let valStr = varValue.toString()
        result = result.replace("$" & varName, valStr)
        result = result.replace("$" & varName.toUpperAscii(), valStr)
        # Also handle capitalized version
        if varName.len > 0:
            let capitalized = varName[0].toUpperAscii() & varName[1..^1]
            result = result.replace("$" & capitalized, valStr)

proc substituteVariables*(rf: Run3File, value: string): string =
    ## Substitute $variable and ${variable} references in a string
    ## Substitutes all variables defined in the runfile
    ## Handles complex expressions like ${version.split('.')[0:2].join('.')}
    rf.substituteVariablesWithTable(rf.getAllVariablesRaw(), value)

proc getVariable*(rf: Run3File, name: string): string =
    ## Get a variable value from the parsed runfile (with substitution)
    rf.substituteVariables(rf.getVariableRaw(name))

proc getVariable*(rf: Run3File, name: string, override: Config, section,
        key: string): string =
    ## Get a variable value with override support
    ## 1. Gets raw value
    ## 2. Checks override
    ## 3. Substitutes variables
    let raw = rf.getVariableRaw(name)
    let overridden = if override != nil: override.getSectionValue(section, key, raw) else: raw
    return rf.substituteVariables(overridden)

proc getListVariable*(rf: Run3File, name: string): seq[string] =
    ## Get a list variable value from the parsed runfile (with substitution)
    let rawList = rf.getListVariableRaw(name)
    result = @[]
    for item in rawList:
        result.add(rf.substituteVariables(item))

proc getListVariable*(rf: Run3File, name: string, override: Config, section,
        key: string): seq[string] =
    ## Get a list variable with override support
    ## Preserves list structure for items with spaces if not overridden

    # 1. Get all variables to check type
    let allVars = rf.getAllVariablesRaw()

    # 2. Get raw string representation
    var rawString = ""
    var isList = false
    var rawList: seq[string] = @[]

    if allVars.hasKey(name):
        let v = allVars[name]
        if v.isList:
            isList = true
            rawList = v.toList()
            rawString = v.toString()
        else:
            rawString = v.toString()

    # 3. Check override
    let overriddenString = if override != nil: override.getSectionValue(section,
            key, rawString) else: rawString

    # 4. If NOT overridden and is native list, preserve structure
    if overriddenString == rawString and isList:
        result = @[]
        for item in rawList:
            result.add(rf.substituteVariables(item))
        return result

    # 5. If overridden or string, treat as string and split
    let substitutedString = rf.substituteVariables(overriddenString)
    if substitutedString.len == 0: return @[]

    result = substitutedString.split(" ")
    result.keepItIf(it.len > 0)

proc hasFunction*(rf: Run3File, name: string): bool =
    ## Check if a function exists in the runfile
    return ast.hasFunction(rf.parsed, name)

proc initRun3ContextFromParsed*(parsed: ParsedScript, destDir: string = "",
        srcDir: string = "", buildRoot: string = ""): Run3Context =
    ## Initialize Run3Context from a parsed script
    result = initRun3Context(destDir, srcDir, buildRoot, "")
    result.loadVariablesFromParsed(parsed)
    result.loadAllFunctions(parsed)

    # Set package name if available
    if result.variables.hasKey("name"):
        result.packageName = result.variables["name"]

proc executeFunction*(rf: Run3File, functionName: string, destDir: string = "",
        srcDir: string = "", buildRoot: string = ""): int =
    ## Execute a specific function from the run3 file
    let ctx = initRun3ContextFromParsed(rf.parsed, destDir, srcDir, buildRoot)
    return executeFunctionByName(ctx, rf.parsed, functionName)

proc getAllFunctions*(rf: Run3File): seq[string] =
    ## Get a list of all function names defined in the runfile
    result = @[]
    for funcNode in rf.parsed.functions:
        if funcNode.kind == nkFunction:
            result.add(funcNode.funcName)

proc getAllCustomFunctions*(rf: Run3File): seq[string] =
    ## Get a list of all custom function names defined in the runfile
    result = @[]
    for funcNode in rf.parsed.customFuncs:
        if funcNode.kind == nkCustomFunc:
            result.add(funcNode.customFuncName)

proc getAllVariables*(rf: Run3File): Table[string, VarValue] =
    ## Get all variables as a table, without substitution on values themselves (returns raw structure)
    return rf.getAllVariablesRaw()

# Convenience procs for common runfile variables

proc getName*(rf: Run3File): string =
    ## Get the package name
    rf.getVariable("name")

proc getVersion*(rf: Run3File): string =
    ## Get the package version
    rf.getVariable("version")

proc getRelease*(rf: Run3File): string =
    ## Get the package release
    rf.getVariable("release")

proc getDescription*(rf: Run3File): string =
    ## Get the package description
    rf.getVariable("description")

proc getSources*(rf: Run3File): seq[string] =
    ## Get the package sources
    rf.getListVariable("sources")

proc getSourcesRaw*(rf: Run3File): seq[string] =
    ## Get the raw package sources without variable substitution
    rf.getListVariableRaw("sources")

proc substituteVariablesWithVersion*(rf: Run3File, value: string,
        newVersion: string): string =
    ## Substitute variables in a string, but override the version variable with newVersion
    ## This is useful for autoupdating source URLs with a new version
    var modifiedVars = rf.getAllVariablesRaw()
    modifiedVars["version"] = newStringValue(newVersion)
    rf.substituteVariablesWithTable(modifiedVars, value)

proc getSourcesWithVersion*(rf: Run3File, newVersion: string): seq[string] =
    ## Get the package sources with a different version substituted
    ## This properly handles expressions like ${version.split('.')[0:2].join('.')}
    let rawSources = rf.getSourcesRaw()
    result = @[]
    for source in rawSources:
        result.add(rf.substituteVariablesWithVersion(source, newVersion))

proc getDepends*(rf: Run3File): seq[string] =
    ## Get the package dependencies
    rf.getListVariable("depends")

proc getBuildDepends*(rf: Run3File): seq[string] =
    ## Get the package build dependencies
    rf.getListVariable("build_depends")

proc getSha256sum*(rf: Run3File): seq[string] =
    ## Get the SHA256 checksums
    rf.getListVariable("sha256sum")

proc getSha512sum*(rf: Run3File): seq[string] =
    ## Get the SHA512 checksums
    rf.getListVariable("sha512sum")

proc getB2sum*(rf: Run3File): seq[string] =
    ## Get the BLAKE2 checksums
    rf.getListVariable("b2sum")

proc getExtract*(rf: Run3File): bool =
    ## Get the extract flag (defaults to true)
    let extract = rf.getVariable("extract")
    if extract == "":
        return true # Default
    return kongueUtils.isTrueBoolean(extract)

proc getAutocd*(rf: Run3File): bool =
    ## Get the autocd flag
    ## Defaults to true, but if extract is explicitly false and autocd is not set,
    ## autocd defaults to false
    let autocd = rf.getVariable("autocd")
    let extract = rf.getVariable("extract")

    if autocd == "":
        # If autocd not set, default based on extract setting
        # If extract is explicitly false, autocd defaults to false
        if extract != "" and not kongueUtils.isTrueBoolean(extract):
            return false
        return true # Default
    return kongueUtils.isTrueBoolean(autocd)

proc getVersionString*(rf: Run3File): string =
    ## Get the full version string (version-release or version-release-epoch)
    let version = rf.getVersion()
    let release = rf.getRelease()
    let epoch = rf.getVariable("epoch")

    if epoch != "" and epoch != "no":
        return version & "-" & release & "-" & epoch
    else:
        return version & "-" & release

# Compatibility wrapper for parseRunfile
proc parseRunfile*(path: string, removeLockfileWhenErr = true): Run3File =
    ## Parse a run3 file (compatibility wrapper)
    ## Expects path to be the package directory containing run3 file
    return parseRun3(path)
