import unittest, tables, strutils
import ../../kpkg/modules/telemetry/main
import ../../kpkg/modules/telemetry/protobuf
import ../../kpkg/modules/telemetry/exporter

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

  test "completion after shutdown is not queued":
    initializeTelemetry(enabledSettings())
    defer:
      setShutdownBeforeQueueAppendForTesting(false)
      shutdownTelemetry()

    let span = startSpan("shutdown")
    setShutdownBeforeQueueAppendForTesting(true)
    endSpan(span)

    check completedSpanCountForTesting() == 0

  test "shutdown exports completed spans as one HTTP batch":
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

    check exportedRequests.len == 1
    check exportedRequests[0].url == "http://collector.example/v1/traces"
    check exportedRequests[0].body.len > 0

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
    defer:
      setTelemetryTransportForTesting(nil)
      shutdownTelemetry()

    endSpan(startSpan("failing"))
    expect TelemetryRuntimeError:
      shutdownTelemetry()

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
