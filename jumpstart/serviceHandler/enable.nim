import os
include ../commonImports
import ../types
import ../../common/logging

proc enableUnit*(unit: string, kind: UnitKind) =
  ## Enables a unit (service, mount, or timer).
  ## With the new .kg format, all units are in configPath
  ## The 'kind' parameter is kept for API compatibility but is now optional

  let unitFile = unit & ".kg"
  let unitPath = configPath & "/" & unitFile
  let enabledPath = configPath & "/enabled/" & unitFile

  if not fileExists(unitPath):
    warn "Unit file not found: " & unitPath
    return

  if fileExists(enabledPath) or symlinkExists(enabledPath):
    info "Unit " & unit & " is already enabled, no need to re-enable"
    return

  try:
    discard existsOrCreateDir(configPath & "/enabled")
    createSymlink(unitPath, enabledPath)
    ok "Enabled " & unit
  except CatchableError as e:
    warn "Couldn't enable " & unit & ": " & e.msg
