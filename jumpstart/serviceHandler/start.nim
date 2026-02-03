import osproc
import os
import strutils
import std/threadpool
import status
import ../../common/logging
include ../commonImports
import globalVariables
import ../configParser

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
    processPre = startProcess(command = serviceConfig.execPre,
        options = {poEvalCommand, poUsePath})

  let process = startProcess(command = serviceConfig.exec,
          options = {poEvalCommand, poUsePath, poDaemon})

  services = services&(serviceName: serviceName, process: process,
          processPre: processPre)

  spawn statusDaemon(process, serviceName, serviceConfig.execPost,
          options = {poEvalCommand, poUsePath, poDaemon})
  ok "Started "&serviceName
