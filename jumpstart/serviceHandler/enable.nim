import os
include ../commonImports
import ../types
import ../../common/logging

proc enableUnit*(unit: string, kind: UnitKind) =
  ## Enables an unit (service, mount, or timer).

  var unitPath: string

  case kind:
    of ukService:
      unitPath = servicePath
    of ukMount:
      unitPath = mountPath
    of ukTimer:
      unitPath = timerPath

  if dirExists(unitPath&"/enabled/"&unit):
    info "Unit "&unit&" is already enabled, no need to re-enable"
    return

  try:
    discard existsOrCreateDir(unitPath&"/enabled")
    createSymlink(unitPath&"/"&unit, unitPath&"/enabled/"&unit)
    ok "Enabled "&unit
  except CatchableError:
    warn "Couldn't enable "&unit&", what is going on?"
