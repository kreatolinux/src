import ../../common/logging
import osproc
import os
import globalVariables
import ../commonImports

proc stopService*(serviceName: string) =

  if not dirExists(serviceHandlerPath&"/"&serviceName):
    info "Service "&serviceName&" is already not running, not trying to stop"
    return

  var service: Service

  for i in 0 .. services.len:
    if services[i].serviceName == serviceName:
      service = services[i]
      info "Stopping service "&serviceName
      info "PID: "&($processID(service.process))
      debug "Terminating process"
      terminate(service.process)
      var val = 0

      try:
        while running(service.process):
          debug "Waiting for process to terminate"
          if val == 10:
            debug "Killing process"
            kill(service.process)
            break
          sleep(1)
          val += 1
      except:
        discard

      debug "Closing process"
      close(service.process)

      if services.find(service) != -1:
        services.del(services.find(service))

      return

  info "Service "&serviceName&" stopped"

