import std/[locks, sysrand, strutils, tables, times]
import ./types
import ../../../common/logging

export types

type
  SpanStatus* = enum
    spanUnset
    spanOk
    spanError

  Span* = ref object
    traceId*: string
    spanId*: string
    parentSpanId*: string
    name*: string
    startedAtNs*: int64
    endedAtNs*: int64
    status*: SpanStatus
    attributes*: Table[string, string]
    errorType*: string
    errorMessage*: string

var telemetryEnabled: bool
var telemetryFailurePolicy: TelemetryFailurePolicy
var completedSpans: seq[Span]
var completedSpansLock: Lock
var currentSpan {.threadvar.}: Span
var spanStack {.threadvar.}: seq[Span]
var randomFailureForTesting: bool

initLock(completedSpansLock)

const safeAttributes = [
  "kpkg.command", "kpkg.version", "host.name", "kpkg.target",
  "package.name", "package.version", "package.repository",
  "package.bootstrap", "package.cache_hit", "source.kind",
  "source.filename", "error.type"
]

proc timestampNs(): int64 =
  int64(epochTime() * 1_000_000_000)

proc randomHex(byteCount: Natural): string =
  if randomFailureForTesting:
    raise newException(OSError, "")
  for value in urandom(byteCount):
    result.add(toHex(value, 2))

proc isSafeAttribute*(key: string): bool =
  key in safeAttributes

proc initializeTelemetry*(settings: TelemetrySettings) =
  telemetryEnabled = settings.enabled
  telemetryFailurePolicy = settings.failurePolicy
  acquire(completedSpansLock)
  try:
    {.cast(gcsafe).}:
      completedSpans.setLen(0)
  finally:
    release(completedSpansLock)
  currentSpan = nil
  spanStack.setLen(0)

proc shutdownTelemetry*() =
  telemetryEnabled = false
  acquire(completedSpansLock)
  try:
    {.cast(gcsafe).}:
      completedSpans.setLen(0)
  finally:
    release(completedSpansLock)
  currentSpan = nil
  spanStack.setLen(0)

proc startSpan*(name: string,
    attributes = initTable[string, string]()): Span =
  if not telemetryEnabled:
    return
  var safeAttributes = initTable[string, string]()
  for key, value in attributes:
    if isSafeAttribute(key):
      safeAttributes[key] = value
  try:
    result = Span(
      traceId: if currentSpan.isNil: randomHex(16) else: currentSpan.traceId,
      spanId: randomHex(8),
      parentSpanId: if currentSpan.isNil: "" else: currentSpan.spanId,
      name: name,
      startedAtNs: timestampNs(),
      attributes: safeAttributes
    )
  except OSError:
    if telemetryFailurePolicy == telemetryFail:
      raise newException(TelemetryRuntimeError,
          "Unable to generate telemetry span identifiers")
    warn "kpkg telemetry: unable to generate span identifiers"
    return
  spanStack.add(result)
  currentSpan = result

proc setRandomFailureForTesting*(enabled: bool) =
  randomFailureForTesting = enabled

proc markSpanError(span: Span, failure: ref Exception) =
  span.status = spanError
  span.errorType = $failure.name
  span.errorMessage = "telemetry span failed"

proc endSpan*(span: Span, failure: ref CatchableError = nil) {.gcsafe.} =
  if span.isNil or span.endedAtNs != 0:
    return
  span.endedAtNs = timestampNs()
  if not failure.isNil:
    markSpanError(span, failure)
  elif span.status != spanError:
    span.status = spanOk
  for index in countdown(spanStack.high, 0):
    if spanStack[index] == span or spanStack[index].endedAtNs != 0:
      spanStack.delete(index)
  currentSpan = if spanStack.len == 0: nil else: spanStack[^1]
  if telemetryEnabled:
    acquire(completedSpansLock)
    try:
      # The lock makes this shared GC-managed queue safe across worker threads.
      {.cast(gcsafe).}:
        completedSpans.add(span)
    finally:
      release(completedSpansLock)

proc completedSpanCountForTesting*(): int {.gcsafe.} =
  acquire(completedSpansLock)
  try:
    {.cast(gcsafe).}:
      result = completedSpans.len
  finally:
    release(completedSpansLock)

proc activeSpanForTesting*(): Span =
  currentSpan

proc lastCompletedSpanForTesting*(): Span {.gcsafe.} =
  acquire(completedSpansLock)
  try:
    {.cast(gcsafe).}:
      if completedSpans.len > 0:
        result = completedSpans[^1]
  finally:
    release(completedSpansLock)

template withSpan*(name: string, body: untyped): untyped =
  block:
    let span = startSpan(name)
    try:
      body
    except Exception as failure:
      if not span.isNil:
        markSpanError(span, failure)
      endSpan(span)
      raise
    finally:
      endSpan(span)
