import osproc
import os
import strutils
import status
import ../../common/logging
include ../commonImports
import globalVariables
import ../configParser
import ../exec

proc startService*(serviceName: string) =
  ## Start a service.
  ## serviceName can be either:
  ##   - A simple name like "example" (looks for example.kg)
  ##   - A qualified name like "example::main" (looks for example.kg, service "main")

  var unitName = serviceName
  var subServiceName = "main"

  # Check for qualified name (unit::subunit)
  if "::" in serviceName:
    let parts = serviceName.split("::", 1)
    unitName = parts[0]
    subServiceName = parts[1]

  # Check if already running
  if dirExists(serviceHandlerPath&"/"&serviceName):
    warn "Service "&serviceName&" is already running, not starting it again"
    return

  # Load and parse the unit configuration
  var config: UnitConfig
  try:
    config = parseUnit(configPath, unitName)
  except CatchableError as e:
    warn "Service "&serviceName&" couldn't be started: "&e.msg
    return

  # Find the matching service config
  var serviceConfig: ServiceConfig
  var found = false
  for svc in config.services:
    if svc.name == subServiceName:
      serviceConfig = svc
      found = true
      break

  if not found:
    # For simple/oneshot types, there should be a single unnamed service
    if config.services.len == 1:
      serviceConfig = config.services[0]
      found = true
    else:
      warn "Service "&serviceName&" not found in unit configuration"
      return

  if serviceConfig.exec == "":
    warn "Service "&serviceName&" has no exec command"
    return

  createDir(serviceHandlerPath&"/"&serviceName)

  var processPre: Process
  if serviceConfig.execPre != "":
    processPre = execDirect(serviceConfig.execPre, options = {poUsePath})
    discard waitForExit(processPre) # Wait for pre-exec to complete

  # Services inherit PID 1's standard streams. In particular, getty must
  # write its login prompt to the active virtual terminal and accept keyboard
  # input; osproc's default anonymous pipes have no reader in Jumpstart.
  let process = execDirect(serviceConfig.exec, options = serviceProcessOptions)

  let statusThread = cast[ptr Thread[StatusThreadArgs]](
      allocShared0(sizeof(Thread[StatusThreadArgs])))
  createThread(statusThread[], statusThreadMain, (process: process,
      serviceName: serviceName, command: serviceConfig.execPost,
      options: serviceProcessOptions))

  services.add((serviceName: serviceName, process: process,
      processPre: processPre, statusThread: statusThread))
  ok "Started "&serviceName
