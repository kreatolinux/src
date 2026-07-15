import std/[locks, sysrand, strutils, tables, times]
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
var completedLogs: seq[LogRecord]
var completedSpansLock: Lock
var currentSpan {.threadvar.}: Span
var spanStack {.threadvar.}: seq[Span]
var randomFailureForTesting: bool
var shutdownBeforeQueueAppendForTesting: bool

initLock(completedSpansLock)

proc timestampNs(): int64 =
  int64(epochTime() * 1_000_000_000)

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
      completedLogs.setLen(0)
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

proc flushTelemetry*() {.gcsafe.} =
  var spans: seq[Span]
  var logs: seq[LogRecord]
  var settings: TelemetrySettings
  var transport: TelemetryTransport
  var hasSpans, hasLogs: bool
  acquire(completedSpansLock)
  try:
    {.cast(gcsafe).}:
      hasSpans = completedSpans.len > 0
      hasLogs = completedLogs.len > 0
    if not telemetryEnabled or (not hasSpans and not hasLogs):
      return
    {.cast(gcsafe).}:
      spans = completedSpans
      completedSpans.setLen(0)
      logs = completedLogs
      completedLogs.setLen(0)
    {.cast(gcsafe).}:
      settings = telemetrySettings
      transport = telemetryTransport
  finally:
    release(completedSpansLock)

  if hasSpans:
    try:
      let payload = encodeExportRequest(spans, {"service.name": "kpkg"}.toTable)
      exportTracePayload(settings, payload, transport)
    except CatchableError:
      if settings.failurePolicy == telemetryFail:
        raise newException(TelemetryRuntimeError, "Unable to export telemetry")
      {.cast(gcsafe).}:
        warn "kpkg telemetry: unable to export traces"
  if hasLogs:
    try:
      let payload = encodeLogExportRequest(logs, {"service.name": "kpkg"}.toTable)
      exportLogPayload(settings, payload, transport)
    except CatchableError:
      if settings.failurePolicy == telemetryFail:
        raise newException(TelemetryRuntimeError, "Unable to export telemetry")
      {.cast(gcsafe).}:
        warn "kpkg telemetry: unable to export logs"

proc shutdownTelemetry*() {.gcsafe.} =
  try:
    flushTelemetry()
  finally:
    acquire(completedSpansLock)
    try:
      telemetryEnabled = false
      {.cast(gcsafe).}:
        completedSpans.setLen(0)
        completedLogs.setLen(0)
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
    currentSpan.attributes[key] = value

const maxFailureLogLines = 100
const maxFailureLogBytes = 64 * 1024

proc containsCredential(line: string): bool =
  let lowered = line.toLowerAscii()
  for marker in ["password", "token", "secret", "api_key", "apikey",
      "authorization", "bearer ", "credential", "private key"]:
    if marker in lowered:
      return true
  let scheme = lowered.find("://")
  if scheme >= 0:
    let authority = lowered[scheme + 3 .. ^1].split('/')[0]
    return ':' in authority and '@' in authority

proc isEnvironmentAssignment(line: string): bool =
  let trimmed = line.strip()
  if trimmed.startsWith("export ") or trimmed.startsWith("declare -x ") or
      trimmed.startsWith("Environment:"):
    return true
  let separator = trimmed.find('=')
  if separator <= 0:
    return false
  let name = trimmed[0 ..< separator]
  if name[0] notin {'A'..'Z', 'a'..'z', '_'}:
    return false
  for character in name:
    if not (character in {'A'..'Z', 'a'..'z', '0'..'9', '_'}):
      return false
  return true

proc isShellCommandEcho(line: string): bool =
  let trimmed = line.strip(leading = true, trailing = false)
  trimmed.startsWith("$ ") or trimmed.startsWith("+ ")

proc redactPathTokens(line: string): string =
  var index = 0
  while index < line.len:
    let start = index
    while index < line.len and line[index] notin {' ', '\t'}:
      inc index
    let token = line[start ..< index]
    if '/' in token:
      result.add("[REDACTED]")
    else:
      result.add(token)
    while index < line.len and line[index] in {' ', '\t'}:
      result.add(line[index])
      inc index

proc sanitizeFailureOutput*(output: string): string =
  let lines = output.splitLines()
  let first = max(0, lines.len - maxFailureLogLines)
  for index in first ..< lines.len:
    if containsCredential(lines[index]) or isEnvironmentAssignment(lines[index]) or
        isShellCommandEcho(lines[index]) or "://" in lines[index]:
      result.add("[REDACTED]")
    else:
      var printable = ""
      for character in lines[index]:
        if character == '\t' or (character >= ' ' and character <= '~'):
          printable.add(character)
      result.add(redactPathTokens(printable))
    if index + 1 < lines.len:
      result.add('\n')
  if result.len > maxFailureLogBytes:
    result = result[result.len - maxFailureLogBytes .. ^1]

proc recordFailedCommandOutput*(output: string, exitCode: int,
    attributes = initTable[string, string]()) {.gcsafe.} =
  if exitCode == 0:
    return
  acquire(completedSpansLock)
  try:
    if not telemetryEnabled or currentSpan.isNil or currentSpan.traceId.len == 0 or
        currentSpan.spanId.len == 0:
      return
    var safeAttributes = initTable[string, string]()
    for key, value in attributes:
      if isSafeAttribute(key):
        safeAttributes[key] = value
    safeAttributes["process.exit_code"] = $exitCode
    safeAttributes["error.type"] = "command_exit"
    {.cast(gcsafe).}:
      completedLogs.add(LogRecord(
        traceId: if currentSpan.isNil: "" else: currentSpan.traceId,
        spanId: if currentSpan.isNil: "" else: currentSpan.spanId,
        timestampNs: timestampNs(),
        body: sanitizeFailureOutput(output),
        attributes: safeAttributes
      ))
  finally:
    release(completedSpansLock)

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
