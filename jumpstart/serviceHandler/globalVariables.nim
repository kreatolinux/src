import osproc

type
  StatusThreadArgs* = tuple
    process: Process
    serviceName: string
    command: string
    options: set[ProcessOption]

  Service* = tuple
    serviceName: string
    process: Process
    processPre: Process
    statusThread: ptr Thread[StatusThreadArgs]

type TimerData* = tuple
  timerName: string
  thread: ptr Thread[pointer]
  stopFlag: ptr bool

var services*: seq[Service]
var timers*: seq[TimerData]
