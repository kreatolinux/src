import unittest, tables
import ../../kpkg/modules/telemetry/config
import ../../kpkg/modules/telemetry/exporter

suite "telemetry HTTP exporter":
  test "normalizes a bare endpoint to the traces path":
    check normalizeTraceEndpoint("collector.example:4318", false) ==
      "http://collector.example:4318/v1/traces"

  test "normalizes endpoint paths without duplicating the traces path":
    check normalizeTraceEndpoint("https://collector.example/otel/", true) ==
      "https://collector.example/otel/v1/traces"
    check normalizeTraceEndpoint("https://collector.example/v1/traces", true) ==
      "https://collector.example/v1/traces"

  test "builds a protobuf request with basic authorization":
    let settings = TelemetrySettings(
      endpoint: "collector.example:4318",
      tls: false,
      timeoutMs: 1234,
      authType: telemetryAuthBasic,
      username: "user",
      password: "secret"
    )
    let request = buildTraceRequest(settings, "protobuf")

    check request.url == "http://collector.example:4318/v1/traces"
    check request.body == "protobuf"
    check request.timeoutMs == 1234
    check not request.tls
    check request.headers["Content-Type"] == "application/x-protobuf"
    check request.headers["Authorization"] == "Basic dXNlcjpzZWNyZXQ="

  test "builds an HTTPS request with verified TLS and bearer authorization":
    let settings = TelemetrySettings(
      endpoint: "collector.example",
      tls: true,
      timeoutMs: 5000,
      authType: telemetryAuthBearer,
      bearerToken: "token"
    )
    let request = buildTraceRequest(settings, "protobuf")

    check request.url == "https://collector.example/v1/traces"
    check request.tls
    check request.verifyTls
    check request.verifyHostname
    check request.headers["Authorization"] == "Bearer token"

  test "rejects unsafe endpoint components":
    for endpoint in [
      "https://user:password@collector.example",
      "https://collector.example/v1/traces#secret",
      "ftp://collector.example"
    ]:
      expect TelemetryRuntimeError:
        discard normalizeTraceEndpoint(endpoint, true)

  test "raises on an unsuccessful collector response":
    let settings = TelemetrySettings(endpoint: "collector.example", tls: false,
      timeoutMs: 5000)
    let transport: TelemetryTransport = proc(request: TelemetryHttpRequest): int =
      check request.url == "http://collector.example/v1/traces"
      503

    expect TelemetryRuntimeError:
      exportTracePayload(settings, "protobuf", transport)
