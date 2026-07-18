import unittest, os, net, tables, strutils
import ../../kpkg/modules/telemetry/main
import ../../kpkg/modules/telemetry/protobuf
import ../../kpkg/modules/telemetry/exporter
import ../../kpkg/modules/run3/run3
import ../../common/logging

proc enabledSettings(policy = telemetryContinue): TelemetrySettings =
  TelemetrySettings(enabled: true, failurePolicy: policy)

proc completeSpanInThread(span: Span) {.thread.} =
  endSpan(span)

var exportedRequests: seq[TelemetryHttpRequest]

proc recordingTransport(request: TelemetryHttpRequest): int {.gcsafe.} =
  {.cast(gcsafe).}:
    exportedRequests.add(request)
  200

proc failingTransport(request: TelemetryHttpRequest): int {.gcsafe.} =
  raise newException(OSError, "password=secret")

proc statusTransport(request: TelemetryHttpRequest): int {.gcsafe.} =
  503

proc timeoutTransport(request: TelemetryHttpRequest): int {.gcsafe.} =
  raise newException(TimeoutError,
      "https://user:password@private.example.invalid/secret-path?token=secret")

proc captureExportWarnings(transport: TelemetryTransport): string =
  let logPath = getTempDir() / "kpkg-telemetry-export-warning-test.log"
  if fileExists(logPath):
    removeFile(logPath)
  setFileLogging(true, logPath)
  try:
    initializeTelemetry(TelemetrySettings(enabled: true,
      endpoint: "https://private.example.invalid/secret-path",
      authType: telemetryAuthBearer, bearerToken: "header-secret",
      timeoutMs: 5000, failurePolicy: telemetryContinue))
    setTelemetryTransportForTesting(transport)
    endSpan(startSpan("kpkg.package.build"))
    flushTelemetry()
    readFile(logPath)
  finally:
    setTelemetryTransportForTesting(nil)
    shutdownTelemetry()
    setFileLogging(false)
    if fileExists(logPath):
      removeFile(logPath)

type ProtoField = object
  number: uint64
  wireType: uint64
  bytes: string
  varint: uint64

proc readVarint(payload: string, index: var int): uint64 =
  var shift = 0
  while true:
    if index >= payload.len or shift > 63:
      raise newException(ValueError, "Invalid test protobuf")
    let value = uint64(ord(payload[index]))
    inc index
    result = result or ((value and 0x7f) shl shift)
    if value < 0x80:
      return
    shift += 7

proc decodeFields(payload: string): seq[ProtoField] =
  var index = 0
  while index < payload.len:
    let tag = readVarint(payload, index)
    var field = ProtoField(number: tag shr 3, wireType: tag and 7)
    case field.wireType
    of 0:
      field.varint = readVarint(payload, index)
    of 1:
      if index + 8 > payload.len:
        raise newException(ValueError, "Invalid test protobuf")
      field.bytes = payload[index ..< index + 8]
      index += 8
    of 2:
      let length = int(readVarint(payload, index))
      if length < 0 or index + length > payload.len:
        raise newException(ValueError, "Invalid test protobuf")
      field.bytes = payload[index ..< index + length]
      index += length
    else:
      raise newException(ValueError, "Unsupported test protobuf wire type")
    result.add(field)

proc field(fields: seq[ProtoField], number: uint64, occurrence = 0): ProtoField =
  var matched = 0
  for value in fields:
    if value.number == number:
      if matched == occurrence:
        return value
      inc matched
  raise newException(ValueError, "Missing test protobuf field")

proc fieldCount(fields: seq[ProtoField], number: uint64): int =
  for value in fields:
    if value.number == number:
      inc result

proc attributeValue(attributes: seq[ProtoField], key: string): string =
  for attribute in attributes:
    let keyValue = decodeFields(attribute.bytes)
    if field(keyValue, 1).bytes == key:
      return field(decodeFields(field(keyValue, 2).bytes), 1).bytes
  raise newException(ValueError, "Missing test protobuf attribute")

proc logAttributes(fields: seq[ProtoField]): seq[ProtoField] =
  for value in fields:
    if value.number == 6:
      result.add(value)

suite "telemetry tracing":
  test "nested spans retain trace identity and parent context":
    initializeTelemetry(enabledSettings())
    defer: shutdownTelemetry()

    let parent = startSpan("parent")
    let child = startSpan("child")
    let sibling = startSpan("sibling")

    check parent.traceId.len == 32
    check parent.spanId.len == 16
    check child.traceId == parent.traceId
    check child.parentSpanId == parent.spanId
    check sibling.parentSpanId == child.spanId

    endSpan(sibling)
    endSpan(child)
    let resumed = startSpan("resumed")
    check resumed.parentSpanId == parent.spanId
    endSpan(resumed)
    endSpan(parent)

  test "disabled telemetry leaves no active span or queue entry":
    initializeTelemetry(TelemetrySettings(enabled: false))
    defer: shutdownTelemetry()

    let span = startSpan("disabled")
    endSpan(span)

    check span.isNil
    check activeSpanForTesting().isNil
    check completedSpanCountForTesting() == 0

  test "random failure continues without changing span context":
    initializeTelemetry(enabledSettings(telemetryContinue))
    setRandomFailureForTesting(true)
    defer:
      setRandomFailureForTesting(false)
      shutdownTelemetry()

    check startSpan("random failure").isNil
    check activeSpanForTesting().isNil
    check completedSpanCountForTesting() == 0

  test "random failure raises when telemetry must fail":
    initializeTelemetry(enabledSettings(telemetryFail))
    setRandomFailureForTesting(true)
    defer:
      setRandomFailureForTesting(false)
      shutdownTelemetry()

    expect TelemetryRuntimeError:
      discard startSpan("random failure")

  test "out-of-order completion removes ended parent context":
    initializeTelemetry(enabledSettings())
    defer: shutdownTelemetry()

    let parent = startSpan("parent")
    let child = startSpan("child")
    endSpan(parent)

    let descendant = startSpan("descendant")
    check descendant.parentSpanId == child.spanId
    endSpan(descendant)
    endSpan(child)

    let root = startSpan("root")
    check root.parentSpanId == ""
    endSpan(root)

  test "completed spans are safe to record concurrently":
    initializeTelemetry(enabledSettings())
    defer: shutdownTelemetry()

    var workers: array[16, Thread[Span]]
    var spans: array[16, Span]
    for index in 0 ..< spans.len:
      spans[index] = Span()
      createThread(workers[index], completeSpanInThread, spans[index])
    for worker in workers.mitems:
      joinThread(worker)

    check completedSpanCountForTesting() == workers.len

  test "spans without OTLP identifiers do not export summaries":
    exportedRequests.setLen(0)
    initializeTelemetry(TelemetrySettings(enabled: true,
      endpoint: "collector.example", timeoutMs: 5000,
      failurePolicy: telemetryContinue))
    setTelemetryTransportForTesting(recordingTransport)
    defer:
      setTelemetryTransportForTesting(nil)
      shutdownTelemetry()

    endSpan(Span())

    check exportedRequests.len == 0

  test "completion after shutdown is not queued":
    initializeTelemetry(enabledSettings())
    defer:
      setShutdownBeforeQueueAppendForTesting(false)
      shutdownTelemetry()

    let span = startSpan("shutdown")
    setShutdownBeforeQueueAppendForTesting(true)
    endSpan(span)

    check completedSpanCountForTesting() == 0

  test "shutdown batches traces after immediate span summaries":
    exportedRequests.setLen(0)
    initializeTelemetry(TelemetrySettings(enabled: true,
      endpoint: "collector.example", timeoutMs: 5000,
      failurePolicy: telemetryContinue))
    setTelemetryTransportForTesting(recordingTransport)
    defer:
      setTelemetryTransportForTesting(nil)
      shutdownTelemetry()

    endSpan(startSpan("first"))
    endSpan(startSpan("second"))
    shutdownTelemetry()

    check exportedRequests.len == 3
    check exportedRequests[0].url == "http://collector.example/v1/logs"
    check exportedRequests[1].url == "http://collector.example/v1/logs"
    check exportedRequests[2].url == "http://collector.example/v1/traces"
    check exportedRequests[2].body.len > 0

  test "completed spans export a success summary immediately":
    exportedRequests.setLen(0)
    initializeTelemetry(TelemetrySettings(enabled: true,
      endpoint: "collector.example", timeoutMs: 5000,
      failurePolicy: telemetryContinue))
    setTelemetryTransportForTesting(recordingTransport)
    defer:
      setTelemetryTransportForTesting(nil)
      shutdownTelemetry()

    let parent = startSpan("kpkg.command")
    let span = startSpan("kpkg.package.build", {
      "package.name": "safe-package",
      "source.url": "https://private.example.invalid"
    }.toTable)
    endSpan(span)

    check exportedRequests.len == 1
    check exportedRequests[0].url == "http://collector.example/v1/logs"
    let request = decodeFields(exportedRequests[0].body)
    let resourceLogs = decodeFields(field(request, 1).bytes)
    let scopeLogs = decodeFields(field(resourceLogs, 2).bytes)
    let logFields = decodeFields(field(scopeLogs, 2).bytes)
    let body = decodeFields(field(logFields, 5).bytes)
    let attributes = logAttributes(logFields)
    check field(body, 1).bytes == "kpkg.package.build completed"
    check attributeValue(attributes, "package.name") == "safe-package"
    check attributeValue(attributes, "span.parent_id") == parent.spanId
    check attributeValue(attributes, "span.status") == "ok"
    check parseInt(attributeValue(attributes, "span.duration_ns")) >= 0
    check field(logFields, 9).bytes.len == 16
    check field(logFields, 10).bytes.len == 8
    check not exportedRequests[0].body.contains("private.example.invalid")
    check exportedRequests.len == 1

  test "failed spans export a sanitized error summary immediately":
    exportedRequests.setLen(0)
    initializeTelemetry(TelemetrySettings(enabled: true,
      endpoint: "collector.example", timeoutMs: 5000,
      failurePolicy: telemetryContinue))
    setTelemetryTransportForTesting(recordingTransport)
    defer:
      setTelemetryTransportForTesting(nil)
      shutdownTelemetry()

    let span = startSpan("kpkg.package.build", {
      "package.name": "safe-package",
      "source.url": "https://user:password@private.example.invalid"
    }.toTable)
    endSpan(span, newException(ValueError, "password=secret"))

    check exportedRequests.len == 1
    check exportedRequests[0].url == "http://collector.example/v1/logs"
    let request = decodeFields(exportedRequests[0].body)
    let resourceLogs = decodeFields(field(request, 1).bytes)
    let scopeLogs = decodeFields(field(resourceLogs, 2).bytes)
    let logFields = decodeFields(field(scopeLogs, 2).bytes)
    let body = decodeFields(field(logFields, 5).bytes)
    let attributes = logAttributes(logFields)
    check field(body, 1).bytes == "kpkg.package.build failed"
    check attributeValue(attributes, "span.status") == "error"
    check attributeValue(attributes, "error.type") == "ValueError"
    check not exportedRequests[0].body.contains("password=secret")
    check not exportedRequests[0].body.contains("private.example.invalid")

  test "OTLP log export encodes severity at the spec field numbers":
    let infoLog = LogRecord(
      traceId: "00112233445566778899aabbccddeeff",
      spanId: "0011223344556677",
      timestampNs: 1_000,
      body: "kpkg.build completed",
      status: spanOk,
      attributes: {"span.status": "ok"}.toTable
    )
    let infoPayload = encodeLogExportRequest([infoLog], {"service.name": "kpkg"}.toTable)
    let infoRequest = decodeFields(infoPayload)
    let infoResourceLogs = decodeFields(field(infoRequest, 1).bytes)
    let infoScopeLogs = decodeFields(field(infoResourceLogs, 2).bytes)
    let infoFields = decodeFields(field(infoScopeLogs, 2).bytes)
    check field(infoFields, 1).wireType == 1
    check field(infoFields, 2).wireType == 0
    check field(infoFields, 2).varint == 9
    check field(infoFields, 3).wireType == 2
    check field(infoFields, 3).bytes == "INFO"
    check fieldCount(infoFields, 4) == 0

    let errorLog = LogRecord(
      traceId: "00112233445566778899aabbccddeeff",
      spanId: "0011223344556677",
      timestampNs: 2_000,
      body: "kpkg.build failed",
      status: spanError,
      attributes: initTable[string, string]()
    )
    let errorPayload = encodeLogExportRequest([errorLog],
        initTable[string, string]())
    let errorRequest = decodeFields(errorPayload)
    let errorResourceLogs = decodeFields(field(errorRequest, 1).bytes)
    let errorScopeLogs = decodeFields(field(errorResourceLogs, 2).bytes)
    let errorFields = decodeFields(field(errorScopeLogs, 2).bytes)
    check field(errorFields, 2).wireType == 0
    check field(errorFields, 2).varint == 17
    check field(errorFields, 3).wireType == 2
    check field(errorFields, 3).bytes == "ERROR"
    check fieldCount(errorFields, 4) == 0

  test "continue policy bounds immediate log exports to 2000 milliseconds":
    exportedRequests.setLen(0)
    initializeTelemetry(TelemetrySettings(enabled: true,
      endpoint: "collector.example", timeoutMs: 5000,
      failurePolicy: telemetryContinue))
    setTelemetryTransportForTesting(recordingTransport)
    defer:
      setTelemetryTransportForTesting(nil)
      shutdownTelemetry()

    endSpan(startSpan("kpkg.package.build"))

    check exportedRequests.len == 1
    check exportedRequests[0].timeoutMs == 2000

  test "continue policy classifies HTTP export failures without secrets":
    let warnings = captureExportWarnings(statusTransport)

    check warnings.contains("kpkg telemetry: log export failed: collector HTTP status")
    check warnings.contains("kpkg telemetry: trace export failed: collector HTTP status")
    check not warnings.contains("503")
    check not warnings.contains("private.example.invalid")
    check not warnings.contains("secret-path")
    check not warnings.contains("token=secret")
    check not warnings.contains("password")
    check not warnings.contains("header-secret")
    check not warnings.contains("Authorization")
    check not warnings.contains("kpkg.package.build")

  test "continue policy classifies timeout export failures without secrets":
    let warnings = captureExportWarnings(timeoutTransport)

    check warnings.contains("kpkg telemetry: log export failed: timeout")
    check warnings.contains("kpkg telemetry: trace export failed: timeout")
    check not warnings.contains("private.example.invalid")
    check not warnings.contains("secret-path")
    check not warnings.contains("token=secret")
    check not warnings.contains("password")
    check not warnings.contains("header-secret")
    check not warnings.contains("Authorization")
    check not warnings.contains("kpkg.package.build")

  test "continue policy uses fallback export failure without secrets":
    let warnings = captureExportWarnings(failingTransport)

    check warnings.contains("kpkg telemetry: log export failed: export failure")
    check warnings.contains("kpkg telemetry: trace export failed: export failure")
    check not warnings.contains("password=secret")
    check not warnings.contains("Authorization")
    check not warnings.contains("kpkg.package.build")

  test "telemetry failure does not replace an exception being unwound":
    initializeTelemetry(TelemetrySettings(enabled: true,
      endpoint: "collector.example", timeoutMs: 5000,
      failurePolicy: telemetryFail))
    setTelemetryTransportForTesting(failingTransport)

    var caught = ""
    try:
      withSpan("kpkg.package.build"):
        raise newException(ValueError, "business failure")
    except CatchableError as failure:
      caught = $failure.name

    check caught == "ValueError"
    setTelemetryTransportForTesting(recordingTransport)
    shutdownTelemetry()
    setTelemetryTransportForTesting(nil)

  test "successful span summaries sanitize error type attributes":
    exportedRequests.setLen(0)
    initializeTelemetry(TelemetrySettings(enabled: true,
      endpoint: "collector.example", timeoutMs: 5000,
      failurePolicy: telemetryContinue))
    setTelemetryTransportForTesting(recordingTransport)
    defer:
      setTelemetryTransportForTesting(nil)
      shutdownTelemetry()

    let span = startSpan("kpkg.package.build", {
      "error.type": "password=secret"
    }.toTable)
    endSpan(span)

    let request = decodeFields(exportedRequests[0].body)
    let resourceLogs = decodeFields(field(request, 1).bytes)
    let scopeLogs = decodeFields(field(resourceLogs, 2).bytes)
    let logFields = decodeFields(field(scopeLogs, 2).bytes)
    check attributeValue(logAttributes(logFields), "error.type") == "error"
    check not exportedRequests[0].body.contains("secret")
    check lastCompletedSpanForTesting().attributes["error.type"] == "error"

  test "span summaries redact unsafe error types":
    exportedRequests.setLen(0)
    initializeTelemetry(TelemetrySettings(enabled: true,
      endpoint: "collector.example", timeoutMs: 5000,
      failurePolicy: telemetryContinue))
    setTelemetryTransportForTesting(recordingTransport)
    defer:
      setTelemetryTransportForTesting(nil)
      shutdownTelemetry()

    let span = Span(
      traceId: "00112233445566778899aabbccddeeff",
      spanId: "0011223344556677",
      name: "kpkg.package.build",
      startedAtNs: 1,
      status: spanError,
      errorType: "password=secret",
      attributes: initTable[string, string]()
    )
    endSpan(span)

    let request = decodeFields(exportedRequests[0].body)
    let resourceLogs = decodeFields(field(request, 1).bytes)
    let scopeLogs = decodeFields(field(resourceLogs, 2).bytes)
    let logFields = decodeFields(field(scopeLogs, 2).bytes)
    check attributeValue(logAttributes(logFields), "error.type") == "error"
    check not exportedRequests[0].body.contains("secret")

  test "Run3 command output is not exported":
    exportedRequests.setLen(0)
    initializeTelemetry(TelemetrySettings(enabled: true,
      endpoint: "collector.example", timeoutMs: 5000,
      failurePolicy: telemetryContinue))
    setTelemetryTransportForTesting(recordingTransport)
    defer:
      setTelemetryTransportForTesting(nil)
      shutdownTelemetry()

    let span = startSpan("kpkg.run3.execute")
    let ctx = initRun3Context(packageName = "safe-package")
    ctx.execHook = proc(ctx: ExecutionContext, command: string,
        silent: bool): tuple[output: string, exitCode: int] =
      ("password=secret", 7)
    check ctx.builtinExec("ignored") == 7
    endSpan(span, newException(ExecutionError, "Run3 execution failed"))

    check exportedRequests.len == 1
    check exportedRequests[0].url == "http://collector.example/v1/logs"
    check not exportedRequests[0].body.contains("password=secret")

  test "shutdown continues when export fails under continue policy":
    initializeTelemetry(TelemetrySettings(enabled: true,
      endpoint: "collector.example", timeoutMs: 5000,
      failurePolicy: telemetryContinue))
    setTelemetryTransportForTesting(failingTransport)
    defer:
      setTelemetryTransportForTesting(nil)
      shutdownTelemetry()

    endSpan(startSpan("failing"))
    shutdownTelemetry()
    check completedSpanCountForTesting() == 0

  test "shutdown raises when export fails under fail policy":
    initializeTelemetry(TelemetrySettings(enabled: true,
      endpoint: "collector.example", timeoutMs: 5000,
      failurePolicy: telemetryFail))
    setTelemetryTransportForTesting(failingTransport)

    expect TelemetryRuntimeError:
      endSpan(startSpan("failing"))
    setTelemetryTransportForTesting(recordingTransport)
    shutdownTelemetry()
    setTelemetryTransportForTesting(nil)

  test "span attributes allow only safe telemetry fields":
    initializeTelemetry(enabledSettings())
    defer: shutdownTelemetry()

    let span = startSpan("attributes", {
      "source.filename": "source.tar.gz",
      "source.url": "https://user:password@example.invalid/source.tar.gz",
      "process.command": "kpkg build --token=secret",
      "config.password": "secret"
    }.toTable)

    check isSafeAttribute("source.filename")
    check not isSafeAttribute("source.url")
    check not isSafeAttribute("process.command")
    check not isSafeAttribute("config.password")
    check span.attributes == {"source.filename": "source.tar.gz"}.toTable
    endSpan(span)

  test "active spans allow cache status to be updated safely":
    initializeTelemetry(enabledSettings())
    defer: shutdownTelemetry()

    let span = startSpan("kpkg.package.build", {
      "package.cache_hit": "false"
    }.toTable)
    setActiveSpanAttribute("package.cache_hit", "true")
    setActiveSpanAttribute("source.url", "https://user:password@example.invalid")
    endSpan(span)

    let completed = lastCompletedSpanForTesting()
    check completed.attributes["package.cache_hit"] == "true"
    check "source.url" notin completed.attributes

  test "withSpan records a sanitized failure and reraises it":
    initializeTelemetry(enabledSettings())
    defer: shutdownTelemetry()

    expect ValueError:
      withSpan("failing"):
        raise newException(ValueError, "password=secret")

    let span = lastCompletedSpanForTesting()
    check span.status == spanError
    check span.errorType == "ValueError"
    check span.errorMessage == "telemetry span failed"
    check "secret" notin span.errorMessage

  test "withSpan marks normal completion successful":
    initializeTelemetry(enabledSettings())
    defer: shutdownTelemetry()

    withSpan("successful"):
      discard

    let span = lastCompletedSpanForTesting()
    check span.status == spanOk
    check span.endedAtNs > 0

  test "withSpan records a defect before reraising it":
    initializeTelemetry(enabledSettings())
    defer: shutdownTelemetry()

    expect AssertionDefect:
      withSpan("defect"):
        raise newException(AssertionDefect, "password=secret")

    let span = lastCompletedSpanForTesting()
    check span.status == spanError
    check span.errorType == "AssertionDefect"
    check span.errorMessage == "telemetry span failed"

  test "OTLP export encodes completed root and child spans":
    let root = Span(
      traceId: "00112233445566778899aabbccddeeff",
      spanId: "0011223344556677",
      name: "kpkg.build",
      startedAtNs: 1_000,
      endedAtNs: 2_000,
      status: spanOk,
      attributes: {"kpkg.command": "build", "secret": "ignored"}.toTable
    )
    let child = Span(
      traceId: "00112233445566778899aabbccddeeff",
      spanId: "8899aabbccddeeff",
      parentSpanId: "0011223344556677",
      name: "kpkg.run.build",
      startedAtNs: 1_100,
      endedAtNs: 1_900,
      status: spanError,
      attributes: {"error.type": "BuildError"}.toTable
    )

    let payload = encodeExportRequest([root, child], {"service.name": "kpkg"}.toTable)
    let request = decodeFields(payload)
    check request.len == 1
    check request[0].number == 1
    check request[0].wireType == 2

    let resourceSpans = decodeFields(request[0].bytes)
    let resource = decodeFields(field(resourceSpans, 1).bytes)
    check fieldCount(resource, 1) == 1
    check attributeValue(resource, "service.name") == "kpkg"

    let scopeSpans = decodeFields(field(resourceSpans, 2).bytes)
    let scope = decodeFields(field(scopeSpans, 1).bytes)
    check field(scope, 1).bytes == "kpkg"

    let rootFields = decodeFields(field(scopeSpans, 2, 0).bytes)
    check field(rootFields, 1).bytes == "\x00\x11\x22\x33\x44\x55\x66\x77\x88\x99\xaa\xbb\xcc\xdd\xee\xff"
    check field(rootFields, 2).bytes == "\x00\x11\x22\x33\x44\x55\x66\x77"
    check field(rootFields, 5).bytes == "kpkg.build"
    check field(rootFields, 7).bytes == "\xe8\x03\0\0\0\0\0\0"
    check field(rootFields, 8).bytes == "\xd0\x07\0\0\0\0\0\0"
    check fieldCount(rootFields, 9) == 1
    check attributeValue(@[field(rootFields, 9)], "kpkg.command") == "build"
    let rootStatus = decodeFields(field(rootFields, 15).bytes)
    check rootStatus.len == 1
    check rootStatus[0].number == 3
    check rootStatus[0].wireType == 0
    check rootStatus[0].varint == 1

    let childFields = decodeFields(field(scopeSpans, 2, 1).bytes)
    check field(childFields, 1).bytes == field(rootFields, 1).bytes
    check field(childFields, 2).bytes == "\x88\x99\xaa\xbb\xcc\xdd\xee\xff"
    check field(childFields, 4).bytes == field(rootFields, 2).bytes
    check field(childFields, 5).bytes == "kpkg.run.build"
    check field(childFields, 7).bytes == "\x4c\x04\0\0\0\0\0\0"
    check field(childFields, 8).bytes == "\x6c\x07\0\0\0\0\0\0"
    check fieldCount(childFields, 9) == 1
    check attributeValue(@[field(childFields, 9)], "error.type") == "BuildError"
    let childStatus = decodeFields(field(childFields, 15).bytes)
    check childStatus[0].number == 3
    check childStatus[0].varint == 2

  test "OTLP export rejects malformed and zero span identifiers":
    let span = Span(
      traceId: "invalid",
      spanId: "0011223344556677",
      name: "kpkg.build",
      startedAtNs: 1,
      endedAtNs: 2,
      status: spanOk,
      attributes: initTable[string, string]()
    )

    expect ValueError:
      discard encodeExportRequest([span], initTable[string, string]())

    span.traceId = repeat("0", 32)
    expect ValueError:
      discard encodeExportRequest([span], initTable[string, string]())

    span.traceId = "00112233445566778899aabbccddeeff"
    span.spanId = repeat("0", 16)
    expect ValueError:
      discard encodeExportRequest([span], initTable[string, string]())

    span.spanId = "0011223344556677"
    span.parentSpanId = repeat("0", 16)
    expect ValueError:
      discard encodeExportRequest([span], initTable[string, string]())

  test "OTLP export rejects nil spans with a telemetry error":
    let spans = [Span(nil)]

    expect TelemetryRuntimeError:
      discard encodeExportRequest(spans, initTable[string, string]())
