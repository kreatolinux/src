## Main entry point for run3 module
## Provides a unified interface for parsing and executing run3 runfiles

import os
import parsecfg
import sequtils
import strutils
import tables
import ast
import builtins
import executor
import lexer
import macros as run3macros
import parser
import variables
import ../logger

export ast, lexer, parser, executor, builtins, variables, run3macros

type
    Run3File* = object
        ## Represents a parsed and ready-to-execute run3 file
        parsed*: ParsedRunfile
        path*: string
        isParsed*: bool

proc parseRun3*(path: string): Run3File =
    ## Parse a run3 file from a package directory
    ## Expects path to be the package directory containing run3 file
    debug "parseRun3: starting for path '"&path&"'"
    result.path = path
    result.isParsed = true
    var run3Path = path / "run3"

    if not fileExists(run3Path):
        if fileExists(path / "run"):
            run3Path = path / "run"
        else:
            raise newException(IOError, "run3 file not found at: " & run3Path)

    debug "parseRun3: calling parseRun3File for '"&run3Path&"'"
    result.parsed = parseRun3File(run3Path)
    debug "parseRun3: parseRun3File completed"

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

proc substituteVariables*(rf: Run3File, value: string): string =
    ## Substitute $variable and ${variable} references in a string
    ## Substitutes all variables defined in the runfile
    let allVars = rf.getAllVariablesRaw()

    result = value

    # Replace ${variable} style references first (more specific)
    for varName, varValue in allVars:
        let valStr = varValue.toString()
        result = result.replace("${" & varName & "}", valStr)
        result = result.replace("${" & varName.toUpperAscii() & "}", valStr)

    # Replace $variable style references (case variations)
    for varName, varValue in allVars:
        let valStr = varValue.toString()
        result = result.replace("$" & varName, valStr)
        result = result.replace("$" & varName.toUpperAscii(), valStr)
        # Also handle capitalized version
        if varName.len > 0:
            let capitalized = varName[0].toUpperAscii() & varName[1..^1]
            result = result.replace("$" & capitalized, valStr)

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
    return rf.parsed.hasFunction(name)

proc executeFunction*(rf: Run3File, functionName: string, destDir: string = "",
        srcDir: string = "", buildRoot: string = ""): int =
    ## Execute a specific function from the run3 file
    let ctx = initFromRunfile(rf.parsed, destDir, srcDir, buildRoot)
    return executeRun3Function(ctx, rf.parsed, functionName)

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
    return extract.toLowerAscii() in ["true", "1", "yes", "y", "on"]

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
