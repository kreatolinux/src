#[
  This module handles Run3 execution context initialization for the builder.
  
  Extracted from buildcmd.nim to provide a clean interface for
  setting up the Run3 execution context with proper environment.
]#

import tables
import ./types
import ../runparser
import ../run3/run3
import ../run3/executor
import ../commonPaths

proc initBuildContext*(cfg: BuildConfig, state: BuildState): ExecutionContext =
  ## Creates and configures Run3 execution context for building.
  ##
  ## Parameters:
  ##   cfg: Build configuration
  ##   state: Build state with parsed runfile and environment
  ##
  ## Returns configured ExecutionContext ready for build step execution.

  let ctx = initFromRunfile(state.pkg.run3Data.parsed, destDir = kpkgBuildRoot,
          srcDir = cfg.srcDir, buildRoot = kpkgBuildRoot)

  # Apply environment variables
  for k, v in state.envVars:
    ctx.envVars[k] = v

  ctx.passthrough = cfg.noSandbox

  return ctx
