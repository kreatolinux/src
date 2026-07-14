import unittest, tables, strutils
import ../../kpkg/modules/telemetry/main

proc enabledSettings(): TelemetrySettings =
  TelemetrySettings(enabled: true)

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

  test "disabled telemetry retains spans without queueing them":
    initializeTelemetry(TelemetrySettings(enabled: false))
    defer: shutdownTelemetry()

    let span = startSpan("disabled")
    endSpan(span)

    check span.traceId.len == 32
    check span.endedAtNs > 0
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
