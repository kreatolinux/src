import os
include ../commonImports
import ../unitname
import ../../common/logging

proc enableUnit*(unit: string) =
  ## Enables a unit (service, mount, or timer).
  ## With the new .kg format, all units are in configPath

  let definitionName = unitBaseName(unit)
  let unitFile = definitionName & ".kg"
  let unitPath = configPath & "/" & unitFile
  let enabledPath = configPath & "/enabled/" & unitFile

  if not fileExists(unitPath):
    warn "Unit file not found: " & unitPath
    return

  if fileExists(enabledPath) or symlinkExists(enabledPath):
    info "Unit " & definitionName & " is already enabled, no need to re-enable"
    return

  try:
    discard existsOrCreateDir(configPath & "/enabled")
    createSymlink(unitPath, enabledPath)
    ok "Enabled " & definitionName
  except CatchableError as e:
    warn "Couldn't enable " & unit & ": " & e.msg
