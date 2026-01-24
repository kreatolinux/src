import osproc

type Service* = tuple
  serviceName: string
  process: Process
  processPre: Process

type TimerData* = tuple
  timerName: string
  thread: Thread[pointer]
  stopFlag: ptr bool

var services*: seq[Service]
var timers*: seq[TimerData]
