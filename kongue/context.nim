## Execution context for Kongue scripting language
## Contains the ExecutionContext type and variable management procs

import os
import tables
import ast

type
  ## Hook types for extensibility - allows consumers to customize execution behavior
  ExecHook* = proc(ctx: ExecutionContext, command: string, silent: bool): tuple[output: string, exitCode: int] {.nimcall.}
  MacroHook* = proc(ctx: ExecutionContext, name: string, args: seq[string]): int {.nimcall.}

  ExecutionContext* = ref object of RootObj
    ## Context for executing Kongue code
    ## Inherit from RootObj to allow subclassing for extended contexts
    variables*: Table[string, string]          ## Global variables from header
    listVariables*: Table[string, seq[string]] ## List variables
    localVars*: Table[string, string]          ## Function-local variables
    envVars*: Table[string, string]            ## Environment variable overrides
    customFuncs*: Table[string, seq[AstNode]]  ## Custom function bodies
    currentDir*: string                        ## Current working directory
    previousDir*: string                       ## Previous directory (for cd -)
    destDir*: string                           ## DESTDIR for installation
    srcDir*: string                            ## Source directory
    buildRoot*: string                         ## Build root directory
    packageName*: string                       ## Package name
    silent*: bool                              ## Suppress output
    # Hooks for extensibility
    execHook*: ExecHook                        ## Custom command execution hook
    macroHook*: MacroHook                      ## Custom macro execution hook

proc initExecutionContext*(destDir: string = "", srcDir: string = "",
        buildRoot: string = "", packageName: string = ""): ExecutionContext =
  ## Initialize a new execution context
  result = ExecutionContext()
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
  result.execHook = nil
  result.macroHook = nil

proc setVariable*(ctx: ExecutionContext, name: string, value: string) =
  ## Set a global variable
  ctx.variables[name] = value

proc setListVariable*(ctx: ExecutionContext, name: string, items: seq[string]) =
  ## Set a list variable
  ctx.listVariables[name] = items

proc getVariable*(ctx: ExecutionContext, name: string): string =
  ## Get a variable value (checks local, then global, then built-in)
  if ctx.localVars.hasKey(name):
    return ctx.localVars[name]
  if ctx.variables.hasKey(name):
    return ctx.variables[name]
  # Check environment variables
  if ctx.envVars.hasKey(name):
    return ctx.envVars[name]
  # Check built-in variables
  case name
  of "ROOT":
    return ctx.buildRoot
  of "DESTDIR":
    return ctx.destDir
  of "SRCDIR":
    return ctx.srcDir
  of "PACKAGENAME":
    return ctx.packageName
  else:
    # Fallback to system environment variables
    return getEnv(name)

proc getListVariable*(ctx: ExecutionContext, name: string): seq[string] =
  ## Get a list variable
  if ctx.listVariables.hasKey(name):
    return ctx.listVariables[name]
  return @[]

proc hasVariable*(ctx: ExecutionContext, name: string): bool =
  ## Check if a variable exists
  if ctx.localVars.hasKey(name) or ctx.variables.hasKey(name) or
          ctx.envVars.hasKey(name):
    return true
  # Check built-in variables
  case name
  of "ROOT", "DESTDIR", "SRCDIR", "PACKAGENAME":
    return true
  else:
    return existsEnv(name)

proc hasListVariable*(ctx: ExecutionContext, name: string): bool =
  ## Check if a list variable exists
  return ctx.listVariables.hasKey(name)

proc clearLocalVars*(ctx: ExecutionContext) =
  ## Clear all local variables (called when exiting a function)
  ctx.localVars.clear()
