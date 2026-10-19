## Pure accounting primitives for section 19 limits, early logging, and retry.
import std/[deques, strformat]

const
  MaxMutatingOperations* = 16
  MaxReadOperations* = 64
  MaxResolveOperations* = 256
  MaxSocketConnections* = 256
  MaxNotificationsPerSecond* = 100
  EarlyLogCapacity* = 1024 * 1024
  LogRetryIntervalMs* = 60_000'i64

type
  OperationClass* = enum ocMutating, ocReadOnly, ocResolve
  AdmissionKind* = enum akAdmitted, akQueued, akRejected
  Admission* = object
    kind*: AdmissionKind
    ticket*: uint64
  ResourceAccounting* = object
    mutatingInFlight*, readInFlight*, resolveInFlight*: int
    socketConnections*: int
    mutatingQueue*, resolveQueue*: Deque[uint64]
    nextTicket: uint64
  NotificationWindow* = object
    acceptedAt: Deque[int64]
    dropped*: uint64
  LogRing* = object
    capacity*: int
    lines: Deque[string]
    contentBytes: int
    dropped*: uint64
  LogRetryState* = object
    filesystemsReady*: bool
    writable*: bool
    nextRetryAtMs*: int64

proc operationLimit*(class: OperationClass): int =
  case class
  of ocMutating: MaxMutatingOperations
  of ocReadOnly: MaxReadOperations
  of ocResolve: MaxResolveOperations

proc inFlight*(state: ResourceAccounting; class: OperationClass): int =
  case class
  of ocMutating: state.mutatingInFlight
  of ocReadOnly: state.readInFlight
  of ocResolve: state.resolveInFlight

proc queued*(state: ResourceAccounting; class: OperationClass): int =
  case class
  of ocMutating: state.mutatingQueue.len
  of ocReadOnly: 0
  of ocResolve: state.resolveQueue.len

proc admit*(state: var ResourceAccounting; class: OperationClass): Admission =
  if state.inFlight(class) < operationLimit(class):
    result.kind = akAdmitted
    case class
    of ocMutating: inc state.mutatingInFlight
    of ocReadOnly: inc state.readInFlight
    of ocResolve: inc state.resolveInFlight
  elif class == ocReadOnly:
    result.kind = akRejected
  else:
    inc state.nextTicket
    result = Admission(kind: akQueued, ticket: state.nextTicket)
    if class == ocMutating: state.mutatingQueue.addLast(result.ticket)
    else: state.resolveQueue.addLast(result.ticket)

proc release*(state: var ResourceAccounting; class: OperationClass): Admission =
  ## Returns the FIFO ticket promoted by this release, or akRejected if none.
  case class
  of ocMutating:
    if state.mutatingInFlight <= 0: raise newException(ValueError, "no mutating operation to release")
    dec state.mutatingInFlight
    if state.mutatingQueue.len > 0:
      result = Admission(kind: akAdmitted, ticket: state.mutatingQueue.popFirst())
      inc state.mutatingInFlight
    else: result.kind = akRejected
  of ocReadOnly:
    if state.readInFlight <= 0: raise newException(ValueError, "no read operation to release")
    dec state.readInFlight; result.kind = akRejected
  of ocResolve:
    if state.resolveInFlight <= 0: raise newException(ValueError, "no resolve operation to release")
    dec state.resolveInFlight
    if state.resolveQueue.len > 0:
      result = Admission(kind: akAdmitted, ticket: state.resolveQueue.popFirst())
      inc state.resolveInFlight
    else: result.kind = akRejected

proc classify*(operation: string; mutating: bool): OperationClass =
  ## §19.3 classes: `unit.resolve` has its own 256-slot queued class;
  ## mutating operations queue at 16; read-only and streaming operations are
  ## refused with E_LIMIT beyond 64.
  if operation == "unit.resolve": ocResolve
  elif mutating: ocMutating
  else: ocReadOnly

proc cancelQueued*(state: var ResourceAccounting; class: OperationClass;
                   ticket: uint64): bool =
  ## Remove a waiter that gave up (its client disconnected or its deadline
  ## passed) so a later release never promotes an abandoned ticket.
  ## Returns false when the ticket is not queued (already promoted).
  template removeFrom(queue: var Deque[uint64]) =
    var kept = initDeque[uint64]()
    for item in queue:
      if item == ticket and not result: result = true
      else: kept.addLast item
    queue = kept
  case class
  of ocMutating: removeFrom(state.mutatingQueue)
  of ocResolve: removeFrom(state.resolveQueue)
  of ocReadOnly: result = false

proc isQueued*(state: ResourceAccounting; class: OperationClass;
               ticket: uint64): bool =
  case class
  of ocMutating: ticket in state.mutatingQueue
  of ocResolve: ticket in state.resolveQueue
  of ocReadOnly: false

proc openConnection*(state: var ResourceAccounting): bool =
  if state.socketConnections >= MaxSocketConnections: return false
  inc state.socketConnections; true

proc closeConnection*(state: var ResourceAccounting) =
  if state.socketConnections <= 0: raise newException(ValueError, "no connection to close")
  dec state.socketConnections

proc allowNotification*(window: var NotificationWindow; nowMs: int64): bool =
  while window.acceptedAt.len > 0 and nowMs - window.acceptedAt.peekFirst() >= 1000:
    discard window.acceptedAt.popFirst()
  if window.acceptedAt.len >= MaxNotificationsPerSecond:
    inc window.dropped; return false
  window.acceptedAt.addLast(nowMs); true

proc initLogRing*(capacity = EarlyLogCapacity): LogRing =
  if capacity < 0: raise newException(ValueError, "negative log capacity")
  result.capacity = capacity
  result.lines = initDeque[string]()

proc droppedMarker(dropped: uint64): string =
  &"jumpstart: {dropped} log lines dropped\n"

proc totalBytes(ring: LogRing): int =
  ring.contentBytes + (if ring.dropped > 0: droppedMarker(ring.dropped).len else: 0)

proc addLine*(ring: var LogRing; line: string) =
  ring.lines.addLast(line); ring.contentBytes += line.len
  while ring.totalBytes > ring.capacity and ring.lines.len > 0:
    ring.contentBytes -= ring.lines.peekFirst().len
    discard ring.lines.popFirst()
    inc ring.dropped
  # A very small/zero ring may not even fit its marker; snapshot then stays empty.

proc bufferedBytes*(ring: LogRing): int = min(ring.totalBytes, ring.capacity)
proc bufferedLines*(ring: LogRing): int = ring.lines.len

proc snapshot*(ring: LogRing): seq[string] =
  if ring.dropped > 0:
    let marker = droppedMarker(ring.dropped)
    if marker.len <= ring.capacity: result.add(marker)
  for line in ring.lines: result.add(line)

proc clear*(ring: var LogRing) =
  ring.lines.clear(); ring.contentBytes = 0; ring.dropped = 0

proc initLogRetryState*(filesystemsReady = false): LogRetryState =
  LogRetryState(filesystemsReady: filesystemsReady, writable: false)

proc markFilesystemsReady*(state: var LogRetryState; nowMs: int64) =
  state.filesystemsReady = true
  state.nextRetryAtMs = nowMs

proc writeFailed*(state: var LogRetryState; nowMs: int64) =
  state.writable = false
  state.nextRetryAtMs = nowMs + LogRetryIntervalMs

proc writeSucceeded*(state: var LogRetryState) =
  state.writable = true
  state.nextRetryAtMs = 0

proc shouldTryWrite*(state: LogRetryState; nowMs: int64): bool =
  state.filesystemsReady and (state.writable or nowMs >= state.nextRetryAtMs)
