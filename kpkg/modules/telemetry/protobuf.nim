import std/tables
import ./types

proc appendVarint(output: var string, value: uint64) =
  var remaining = value
  while remaining >= 0x80:
    output.add(char((remaining and 0x7f) or 0x80))
    remaining = remaining shr 7
  output.add(char(remaining))

proc appendTag(output: var string, fieldNumber: uint64, wireType: uint64) =
  output.appendVarint((fieldNumber shl 3) or wireType)

proc appendBytes(output: var string, fieldNumber: uint64, value: string) =
  output.appendTag(fieldNumber, 2)
  output.appendVarint(uint64(value.len))
  output.add(value)

proc appendFixed64(output: var string, fieldNumber: uint64, value: int64) =
  output.appendTag(fieldNumber, 1)
  let bits = cast[uint64](value)
  for shift in countup(0, 56, 8):
    output.add(char((bits shr shift) and 0xff))

proc hexValue(value: char): int =
  case value
  of '0' .. '9': ord(value) - ord('0')
  of 'a' .. 'f': ord(value) - ord('a') + 10
  of 'A' .. 'F': ord(value) - ord('A') + 10
  else: -1

proc decodeHexId(id: string, byteCount: int): string =
  if id.len != byteCount * 2:
    raise newException(ValueError, "Invalid OTLP identifier length")
  var nonZero = false
  for index in countup(0, id.high, 2):
    let high = hexValue(id[index])
    let low = hexValue(id[index + 1])
    if high < 0 or low < 0:
      raise newException(ValueError, "Invalid OTLP identifier")
    nonZero = nonZero or high != 0 or low != 0
    result.add(char((high shl 4) or low))
  if not nonZero:
    raise newException(ValueError, "Invalid zero OTLP identifier")

proc encodeAnyValue(value: string): string =
  result.appendBytes(1, value)

proc encodeKeyValue(key, value: string): string =
  result.appendBytes(1, key)
  result.appendBytes(2, encodeAnyValue(value))

proc encodeAttributes(attributes: Table[string, string], fieldNumber: uint64,
    resource: bool, logRecord = false): string =
  for key, value in attributes:
    if (resource and (key == "service.name" or isSafeAttribute(key))) or
        (not resource and (if logRecord: isSafeLogAttribute(key) else: isSafeAttribute(key))):
      result.appendBytes(fieldNumber, encodeKeyValue(key, value))

proc encodeStatus(status: SpanStatus): string =
  let code = case status
    of spanOk: 1'u64
    of spanError: 2'u64
    of spanUnset: 0'u64
  result.appendTag(3, 0)
  result.appendVarint(code)

proc encodeSpan(span: Span): string =
  result.appendBytes(1, decodeHexId(span.traceId, 16))
  result.appendBytes(2, decodeHexId(span.spanId, 8))
  if span.parentSpanId.len > 0:
    result.appendBytes(4, decodeHexId(span.parentSpanId, 8))
  result.appendBytes(5, span.name)
  result.appendFixed64(7, span.startedAtNs)
  result.appendFixed64(8, span.endedAtNs)
  result.add(encodeAttributes(span.attributes, 9, false))
  result.appendBytes(15, encodeStatus(span.status))

proc encodeExportRequest*(spans: openArray[Span],
    resource: Table[string, string]): string =
  var resourceMessage = encodeAttributes(resource, 1, true)
  var instrumentationScope: string
  instrumentationScope.appendBytes(1, "kpkg")
  var scopeMessage: string
  scopeMessage.appendBytes(1, instrumentationScope)
  for span in spans:
    if span.isNil:
      raise newException(TelemetryRuntimeError, "Cannot encode a nil telemetry span")
    scopeMessage.appendBytes(2, encodeSpan(span))
  var resourceSpans: string
  resourceSpans.appendBytes(1, resourceMessage)
  resourceSpans.appendBytes(2, scopeMessage)
  result.appendBytes(1, resourceSpans)

proc encodeLogRecord(log: LogRecord): string =
  result.appendFixed64(1, log.timestampNs)
  result.appendTag(3, 0)
  let isError = log.status == spanError
  result.appendVarint(if isError: 17 else: 9)
  result.appendBytes(4, if isError: "ERROR" else: "INFO")
  result.appendBytes(5, encodeAnyValue(log.body))
  result.add(encodeAttributes(log.attributes, 6, false, true))
  if log.traceId.len > 0:
    result.appendBytes(9, decodeHexId(log.traceId, 16))
  if log.spanId.len > 0:
    result.appendBytes(10, decodeHexId(log.spanId, 8))

proc encodeLogExportRequest*(logs: openArray[LogRecord],
    resource: Table[string, string]): string =
  var resourceMessage = encodeAttributes(resource, 1, true)
  var instrumentationScope: string
  instrumentationScope.appendBytes(1, "kpkg")
  var scopeMessage: string
  scopeMessage.appendBytes(1, instrumentationScope)
  for log in logs:
    if log.isNil:
      raise newException(TelemetryRuntimeError, "Cannot encode a nil telemetry log")
    scopeMessage.appendBytes(2, encodeLogRecord(log))
  var resourceLogs: string
  resourceLogs.appendBytes(1, resourceMessage)
  resourceLogs.appendBytes(2, scopeMessage)
  result.appendBytes(1, resourceLogs)
