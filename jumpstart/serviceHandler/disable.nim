import os
include ../commonImports
import ../types
import ../../common/logging

proc disableUnit*(unit: string, kind: UnitKind) =
  ## Disables an unit (service, mount, or timer).

  var unitPath: string

  case kind:
    of ukService:
      unitPath = servicePath
    of ukMount:
      unitPath = mountPath
    of ukTimer:
      unitPath = timerPath

  if fileExists(unitPath&"/enabled/"&unit):
    removeFile(unitPath&"/enabled/"&unit)
    ok "Disabled unit "&unit
  else:
    info "Unit "&unit&" is already disabled"
