import std/[sysrand, strutils, tables, times]
import ./types

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
var completedSpans: seq[Span]
var currentSpan {.threadvar.}: Span
var spanStack {.threadvar.}: seq[Span]

const safeAttributes = [
  "kpkg.command", "kpkg.version", "host.name", "kpkg.target",
  "package.name", "package.version", "package.repository",
  "package.bootstrap", "package.cache_hit", "source.kind",
  "source.filename", "error.type"
]

proc timestampNs(): int64 =
  int64(epochTime() * 1_000_000_000)

proc randomHex(byteCount: Natural): string =
  for value in urandom(byteCount):
    result.add(toHex(value, 2))

proc isSafeAttribute*(key: string): bool =
  key in safeAttributes

proc initializeTelemetry*(settings: TelemetrySettings) =
  telemetryEnabled = settings.enabled
  completedSpans.setLen(0)
  currentSpan = nil
  spanStack.setLen(0)

proc shutdownTelemetry*() =
  telemetryEnabled = false
  completedSpans.setLen(0)
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
  result = Span(
    traceId: if currentSpan.isNil: randomHex(16) else: currentSpan.traceId,
    spanId: randomHex(8),
    parentSpanId: if currentSpan.isNil: "" else: currentSpan.spanId,
    name: name,
    startedAtNs: timestampNs(),
    attributes: safeAttributes
  )
  spanStack.add(result)
  currentSpan = result

proc endSpan*(span: Span, failure: ref CatchableError = nil) =
  if span.isNil or span.endedAtNs != 0:
    return
  span.endedAtNs = timestampNs()
  if not failure.isNil:
    span.status = spanError
    span.errorType = $failure.name
    span.errorMessage = "telemetry span failed"
  else:
    span.status = spanOk
  for index in countdown(spanStack.high, 0):
    if spanStack[index] == span or spanStack[index].endedAtNs != 0:
      spanStack.delete(index)
  currentSpan = if spanStack.len == 0: nil else: spanStack[^1]
  if telemetryEnabled:
    completedSpans.add(span)

proc completedSpanCountForTesting*(): int =
  completedSpans.len

proc activeSpanForTesting*(): Span =
  currentSpan

proc lastCompletedSpanForTesting*(): Span =
  if completedSpans.len > 0:
    result = completedSpans[^1]

template withSpan*(name: string, body: untyped): untyped =
  block:
    let span = startSpan(name)
    try:
      body
    except CatchableError as failure:
      endSpan(span, failure)
      raise
    finally:
      endSpan(span)
