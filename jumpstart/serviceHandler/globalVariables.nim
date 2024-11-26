import osproc
type Service* = tuple
    serviceName: string
    process: Process
    processPre: Process

var services*: seq[Service]
