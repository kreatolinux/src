#[
  This module handles build step detection and execution for the builder.
  
  Extracted from buildcmd.nim to provide a clean interface for
  detecting which build functions exist and executing them in order.
]#

import strutils
import ./types
import ../runparser
import ../../../common/logging
import ../run3/run3

proc detectBuildFunctions*(pkg: runFile,
    actualPackage: string): BuildFunctions =
  ## Scans runfile functions to detect which build steps exist.
  ##
  ## Parameters:
  ##   pkg: Parsed runfile
  ##   actualPackage: Package name (used for package-specific function detection)
  ##
  ## Returns BuildFunctions with flags for each detected function.

  result = BuildFunctions(
    prepare: false,
    package: false,
    check: false,
    build: false,
    packageInstall: false,
    packageBuild: false
  )

  let packageSuffix = replace(actualPackage, '-', '_')

  for fn in pkg.functions:
    debug "detectBuildFunctions: checking '" & fn.name & "'"
    case fn.name
    of "prepare":
      result.prepare = true
    of "package":
      result.package = true
    of "check":
      result.check = true
    of "build":
      result.build = true
    else:
      discard

    if fn.name == "package_" & packageSuffix:
      result.packageInstall = true

    if fn.name == "build_" & packageSuffix:
      result.packageBuild = true

proc getBuildFuncName*(exists: BuildFunctions, actualPackage: string): string =
  ## Returns the correct build function name.
  ##
  ## Returns "build_{name}" if it exists, "build" if that exists,
  ## or empty string if no build function exists.

  if exists.packageBuild:
    return "build_" & replace(actualPackage, '-', '_')
  elif exists.build:
    return "build"
  else:
    return ""

proc getPackageFuncName*(exists: BuildFunctions,
    actualPackage: string): string =
  ## Returns the correct package function name.
  ##
  ## Returns "package_{name}" if it exists, "package" if that exists,
  ## or empty string if no package function exists.

  if exists.packageInstall:
    return "package_" & replace(actualPackage, '-', '_')
  elif exists.package:
    return "package"
  else:
    return ""

proc executeBuildSteps*(ctx: ExecutionContext, state: BuildState,
                        actualPackage: string, tests: bool) =
  ## Executes prepare → build → check → package steps in order.
  ##
  ## Parameters:
  ##   ctx: Configured Run3 execution context
  ##   state: Build state with parsed runfile and function info
  ##   actualPackage: Package name
  ##   tests: Whether to run check step
  ##
  ## Calls fatal() on any step failure (does not return).

  # Execute "prepare"
  if state.exists.prepare:
    if executeFunctionByName(ctx, state.pkg.run3Data.parsed, "prepare") != 0:
      fatal("prepare failed")

  # Determine and execute "build"
  let buildFunc = getBuildFuncName(state.exists, actualPackage)
  if buildFunc != "":
    if executeFunctionByName(ctx, state.pkg.run3Data.parsed, buildFunc) != 0:
      fatal("build failed")

  # Execute "check" (tests) if requested
  if tests and state.exists.check:
    if executeFunctionByName(ctx, state.pkg.run3Data.parsed, "check") != 0:
      fatal("check failed")

  # Determine and execute "package"
  let pkgFunc = getPackageFuncName(state.exists, actualPackage)
  if pkgFunc == "":
    fatal("install stage of package doesn't exist, invalid runfile")

  if executeFunctionByName(ctx, state.pkg.run3Data.parsed, pkgFunc) != 0:
    fatal("package install failed")
