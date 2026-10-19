## Event-loop-facing coordinator for the pure section 19 accounting primitives.
##
## The coordinator owns no clocks, files, sockets, or processes. Callers supply
## timestamps and perform effects described by its return values.
import std/tables
import ./resources

type
  OperationAdmission* = object
    core*: string
    class*: OperationClass
    admission*: Admission

  ConnectionAdmission* = enum
    caAccepted, caLimit

  NotificationAdmission* = object
    accepted*: bool
    droppedTotal*: uint64

  LogWritePlan* = object
    ## Empty `lines` means retain the line in memory and perform no I/O.
    lines*: seq[string]

  RuntimeResources* = object
    cores: Table[string, ResourceAccounting]
    connections: ResourceAccounting
    notifications: Table[string, NotificationWindow]
    logBuffer*: LogRing
    logRetry*: LogRetryState

proc initRuntimeResources*(logCapacity = EarlyLogCapacity;
                           filesystemsReady = false): RuntimeResources =
  result.cores = initTable[string, ResourceAccounting]()
  result.notifications = initTable[string, NotificationWindow]()
  result.logBuffer = initLogRing(logCapacity)
  result.logRetry = initLogRetryState(filesystemsReady)

proc admitOperation*(runtime: var RuntimeResources; core: string;
                     class: OperationClass): OperationAdmission =
  ## Limits and FIFO queues are independent for every core.
  result.core = core
  result.class = class
  result.admission = runtime.cores.mgetOrPut(core, ResourceAccounting()).admit(class)

proc completeOperation*(runtime: var RuntimeResources; core: string;
                        class: OperationClass): OperationAdmission =
  ## Completes one running operation and identifies the FIFO waiter promoted.
  ## `admission.kind == akRejected` means that no waiter was promoted.
  if not runtime.cores.hasKey(core):
    raise newException(ValueError, "unknown core: " & core)
  result.core = core
  result.class = class
  result.admission = runtime.cores[core].release(class)

proc cancelQueuedOperation*(runtime: var RuntimeResources; core: string;
                            class: OperationClass; ticket: uint64): bool =
  ## Withdraw a queued waiter (client closed the connection or the request's
  ## deadline passed). False when it was already promoted: the caller then
  ## owns a running slot and must complete it with `completeOperation`.
  if not runtime.cores.hasKey(core): return false
  runtime.cores[core].cancelQueued(class, ticket)

proc ticketQueued*(runtime: RuntimeResources; core: string;
                   class: OperationClass; ticket: uint64): bool =
  runtime.cores.hasKey(core) and runtime.cores[core].isQueued(class, ticket)

proc forgetCore*(runtime: var RuntimeResources; core: string): bool =
  ## Drop an unloaded core's counters. Refused (false) while it still has
  ## running or queued operations.
  if not runtime.cores.hasKey(core): return true
  let accounting = runtime.cores[core]
  for class in OperationClass:
    if accounting.inFlight(class) > 0 or accounting.queued(class) > 0: return false
  runtime.cores.del(core)
  true

proc coreInFlight*(runtime: RuntimeResources; core: string;
                   class: OperationClass): int =
  if not runtime.cores.hasKey(core): 0 else: runtime.cores[core].inFlight(class)

proc coreQueued*(runtime: RuntimeResources; core: string;
                 class: OperationClass): int =
  if not runtime.cores.hasKey(core): 0 else: runtime.cores[core].queued(class)

proc acceptConnection*(runtime: var RuntimeResources): ConnectionAdmission =
  if runtime.connections.openConnection(): caAccepted else: caLimit

proc closeConnection*(runtime: var RuntimeResources) =
  runtime.connections.closeConnection()

proc connectionCount*(runtime: RuntimeResources): int =
  runtime.connections.socketConnections

proc receiveNotification*(runtime: var RuntimeResources; process: string;
                          nowMs: int64): NotificationAdmission =
  ## Windows are per process; rejected notifications are counted for logging.
  result.accepted = runtime.notifications.mgetOrPut(
    process, NotificationWindow()).allowNotification(nowMs)
  result.droppedTotal = runtime.notifications[process].dropped

proc forgetProcess*(runtime: var RuntimeResources; process: string) =
  ## Prevents rate-window state from accumulating after child exit.
  runtime.notifications.del(process)

proc notificationProcessCount*(runtime: RuntimeResources): int =
  runtime.notifications.len

proc filesystemsReady*(runtime: var RuntimeResources; nowMs: int64) =
  runtime.logRetry.markFilesystemsReady(nowMs)

proc planLogWrite*(runtime: var RuntimeResources; line: string;
                   nowMs: int64): LogWritePlan =
  ## Retains every line before proposing I/O. On success, pass this plan to
  ## `finishLogWrite`; on failure all proposed lines remain buffered.
  runtime.logBuffer.addLine(line)
  if runtime.logRetry.shouldTryWrite(nowMs):
    result.lines = runtime.logBuffer.snapshot()

proc finishLogWrite*(runtime: var RuntimeResources; plan: LogWritePlan;
                     success: bool; nowMs: int64) =
  if plan.lines.len == 0:
    raise newException(ValueError, "cannot finish an empty log write plan")
  if success:
    runtime.logBuffer.clear()
    runtime.logRetry.writeSucceeded()
  else:
    runtime.logRetry.writeFailed(nowMs)

proc pendingLogLines*(runtime: RuntimeResources): seq[string] =
  runtime.logBuffer.snapshot()
