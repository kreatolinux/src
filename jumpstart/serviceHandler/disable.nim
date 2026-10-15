import os
include ../commonImports
import ../unitname
import ../../common/logging

proc disableUnit*(unit: string) =
  ## Disables a unit (service, mount, or timer).
  ## With the new .kg format, all units are in configPath

  let definitionName = unitBaseName(unit)
  let unitFile = definitionName & ".kg"
  let enabledPath = configPath & "/enabled/" & unitFile

  if fileExists(enabledPath) or symlinkExists(enabledPath):
    removeFile(enabledPath)
    ok "Disabled unit " & definitionName
  else:
    info "Unit " & definitionName & " is already disabled"
