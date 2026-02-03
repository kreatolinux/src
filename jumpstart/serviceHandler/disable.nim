import os
include ../commonImports
import ../types
import ../../common/logging

proc disableUnit*(unit: string, kind: UnitKind) =
  ## Disables a unit (service, mount, or timer).
  ## With the new .kg format, all units are in configPath
  ## The 'kind' parameter is kept for API compatibility but is now optional

  let unitFile = unit & ".kg"
  let enabledPath = configPath & "/enabled/" & unitFile

  if fileExists(enabledPath) or symlinkExists(enabledPath):
    removeFile(enabledPath)
    ok "Disabled unit " & unit
  else:
    info "Unit " & unit & " is already disabled"
