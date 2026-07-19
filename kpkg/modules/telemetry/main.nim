import std/[locks, net, sysrand, strutils, tables, times]
import ./types
import ./protobuf
import ./exporter
import ../../../common/logging

export types

var telemetryEnabled: bool
var telemetryFailurePolicy: TelemetryFailurePolicy
var telemetrySettings: TelemetrySettings
var telemetryTransport: TelemetryTransport
var completedSpans: seq[Span]
var completedSpansLock: Lock
var currentSpan {.threadvar.}: Span
var spanStack {.threadvar.}: seq[Span]
var randomFailureForTesting: bool
var shutdownBeforeQueueAppendForTesting: bool

initLock(completedSpansLock)

proc timestampNs(): int64 =
  int64(epochTime() * 1_000_000_000)

proc sanitizeErrorType(errorType: string): string

proc exportFailureClass(failure: ref CatchableError): string =
  if failure of TelemetryHttpStatusError:
    "collector HTTP status"
  elif failure of TimeoutError:
    "timeout"
  else:
    "export failure"

proc randomHex(byteCount: Natural): string =
  if randomFailureForTesting:
    raise newException(OSError, "")
  for value in urandom(byteCount):
    result.add(toHex(value, 2))

proc initializeTelemetry*(settings: TelemetrySettings) =
  acquire(completedSpansLock)
  try:
    telemetryEnabled = settings.enabled
    telemetryFailurePolicy = settings.failurePolicy
    telemetrySettings = settings
    {.cast(gcsafe).}:
      completedSpans.setLen(0)
  finally:
    release(completedSpansLock)
  currentSpan = nil
  spanStack.setLen(0)

proc setTelemetryTransportForTesting*(transport: TelemetryTransport) =
  acquire(completedSpansLock)
  try:
    telemetryTransport = transport
  finally:
    release(completedSpansLock)

proc telemetryResource(settings: TelemetrySettings): Table[string, string] =
  result = {"service.name": "kpkg"}.toTable
  if settings.buildId.len > 0:
    result["kpkg.build.id"] = settings.buildId

proc flushTelemetry*() {.gcsafe.} =
  var spans: seq[Span]
  var settings: TelemetrySettings
  var transport: TelemetryTransport
  var hasSpans: bool
  acquire(completedSpansLock)
  try:
    {.cast(gcsafe).}:
      hasSpans = completedSpans.len > 0
    if not telemetryEnabled or not hasSpans:
      return
    {.cast(gcsafe).}:
      spans = completedSpans
      completedSpans.setLen(0)
    {.cast(gcsafe).}:
      settings = telemetrySettings
      transport = telemetryTransport
  finally:
    release(completedSpansLock)

  if hasSpans:
    try:
      let payload = encodeExportRequest(spans, telemetryResource(settings))
      exportTracePayload(settings, payload, transport)
    except CatchableError as failure:
      if settings.failurePolicy == telemetryFail:
        raise newException(TelemetryRuntimeError, "Unable to export telemetry")
      {.cast(gcsafe).}:
        warn "kpkg telemetry: trace export failed: " & exportFailureClass(failure)
proc shutdownTelemetry*() {.gcsafe.} =
  try:
    flushTelemetry()
  finally:
    acquire(completedSpansLock)
    try:
      telemetryEnabled = false
      {.cast(gcsafe).}:
        completedSpans.setLen(0)
    finally:
      release(completedSpansLock)
    currentSpan = nil
    spanStack.setLen(0)

proc startSpan*(name: string,
    attributes = initTable[string, string]()): Span =
  var enabled: bool
  var failurePolicy: TelemetryFailurePolicy
  acquire(completedSpansLock)
  try:
    enabled = telemetryEnabled
    failurePolicy = telemetryFailurePolicy
  finally:
    release(completedSpansLock)
  if not enabled:
    return
  var safeAttributes = initTable[string, string]()
  for key, value in attributes:
    if isSafeAttribute(key):
      safeAttributes[key] = if key == "error.type": sanitizeErrorType(value) else: value
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
    if failurePolicy == telemetryFail:
      raise newException(TelemetryRuntimeError,
          "Unable to generate telemetry span identifiers")
    warn "kpkg telemetry: unable to generate span identifiers"
    return
  spanStack.add(result)
  currentSpan = result

proc setRandomFailureForTesting*(enabled: bool) =
  randomFailureForTesting = enabled

proc setShutdownBeforeQueueAppendForTesting*(enabled: bool) =
  shutdownBeforeQueueAppendForTesting = enabled

proc markSpanError(span: Span, failure: ref Exception) =
  span.status = spanError
  span.errorType = $failure.name
  span.errorMessage = "telemetry span failed"

proc spanStatusName(status: SpanStatus): string =
  case status
  of spanOk: "ok"
  of spanError: "error"
  of spanUnset: "unset"

proc sanitizeErrorType(errorType: string): string =
  if errorType.len == 0:
    return "error"
  for character in errorType:
    if character notin {'A'..'Z', 'a'..'z', '0'..'9', '.', '_'}:
      return "error"
  errorType

proc spanSummary(span: Span): LogRecord =
  var attributes = initTable[string, string]()
  for key, value in span.attributes:
    attributes[key] = value
  if attributes.hasKey("error.type"):
    attributes["error.type"] = sanitizeErrorType(attributes["error.type"])
  attributes["span.parent_id"] = span.parentSpanId
  attributes["span.duration_ns"] = $(span.endedAtNs - span.startedAtNs)
  attributes["span.status"] = spanStatusName(span.status)
  if span.status == spanError:
    attributes["error.type"] = sanitizeErrorType(span.errorType)
  result = LogRecord(
    traceId: span.traceId,
    spanId: span.spanId,
    timestampNs: span.endedAtNs,
    body: span.name & (if span.status == spanError: " failed" else: " completed"),
    status: span.status,
    attributes: attributes
  )

proc exportSpanSummary(span: Span, suppressFailure: bool) {.gcsafe.} =
  if span.traceId.len != 32 or span.spanId.len != 16:
    return
  var settings: TelemetrySettings
  var transport: TelemetryTransport
  var enabled: bool
  var failurePolicy: TelemetryFailurePolicy
  acquire(completedSpansLock)
  try:
    {.cast(gcsafe).}:
      enabled = telemetryEnabled
      settings = telemetrySettings
      transport = telemetryTransport
      failurePolicy = telemetryFailurePolicy
  finally:
    release(completedSpansLock)
  if not enabled:
    return
  try:
    let payload = encodeLogExportRequest([spanSummary(span)],
        telemetryResource(settings))
    let timeoutMs = if failurePolicy == telemetryContinue:
      telemetryContinueLogTimeoutMs
    else:
      settings.timeoutMs
    exportLogPayload(settings, payload, transport, timeoutMs)
  except CatchableError as failure:
    if failurePolicy == telemetryFail and not suppressFailure:
      raise newException(TelemetryRuntimeError, "Unable to export telemetry")
    {.cast(gcsafe).}:
      warn "kpkg telemetry: log export failed: " & exportFailureClass(failure)

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
  if shutdownBeforeQueueAppendForTesting:
    shutdownTelemetry()
  acquire(completedSpansLock)
  try:
    if telemetryEnabled:
      # The lock makes this shared GC-managed queue safe across worker threads.
      {.cast(gcsafe).}:
        completedSpans.add(span)
  finally:
    release(completedSpansLock)
  exportSpanSummary(span, not getCurrentException().isNil)

proc fatalExitCallback*(span: Span): ErrorCallback =
  ## Returns a logging error callback that ends `span` as failed, so a
  ## process aborting through fatal() exports a failure summary instead of
  ## "completed". The exit proc ending the span afterwards is a no-op.
  result = proc(msg: string) =
    endSpan(span, newException(OSError, msg))

proc completedSpanCountForTesting*(): int {.gcsafe.} =
  acquire(completedSpansLock)
  try:
    {.cast(gcsafe).}:
      result = completedSpans.len
  finally:
    release(completedSpansLock)

proc activeSpanForTesting*(): Span =
  currentSpan

proc setActiveSpanAttribute*(key: string, value: string) =
  if not currentSpan.isNil and isSafeAttribute(key):
    currentSpan.attributes[key] =
      if key == "error.type": sanitizeErrorType(value) else: value

proc lastCompletedSpanForTesting*(): Span {.gcsafe.} =
  acquire(completedSpansLock)
  try:
    {.cast(gcsafe).}:
      if completedSpans.len > 0:
        result = completedSpans[^1]
  finally:
    release(completedSpansLock)

template withSpan*(name: string, attributes: untyped, body: untyped): untyped =
  block:
    let span = startSpan(name, attributes)
    try:
      body
    except Exception as failure:
      if not span.isNil:
        markSpanError(span, failure)
      endSpan(span)
      raise
    finally:
      endSpan(span)

template withSpan*(name: string, body: untyped): untyped =
  withSpan(name, initTable[string, string](), body)
