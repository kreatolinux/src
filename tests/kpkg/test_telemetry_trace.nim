import unittest, tables, strutils
import ../../kpkg/modules/telemetry/main
import ../../kpkg/modules/telemetry/protobuf

proc enabledSettings(policy = telemetryContinue): TelemetrySettings =
  TelemetrySettings(enabled: true, failurePolicy: policy)

proc completeSpanInThread(span: Span) {.thread.} =
  endSpan(span)

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

    check "kpkg.build" in payload
    check "kpkg.run.build" in payload
    check "kpkg.command" in payload
    check "secret" notin payload

  test "gRPC records use an uncompressed big-endian payload length":
    let record = grpcRecord("abc")

    check record[] == "\0\0\0\0\3abc"

  test "OTLP export rejects malformed span identifiers":
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
