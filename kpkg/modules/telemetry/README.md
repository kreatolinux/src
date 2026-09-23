# kpkg telemetry

Optional OpenTelemetry-compatible trace and span-summary log export for kpkg.
Telemetry is disabled by default. Call sites in the CLI, builder, Run3, and
other package operations use this module to describe work as nested spans.

## Files and APIs

- `types.nim`: settings, spans, log records, permitted attribute keys, and
  build-ID/command-name validation.
- `config.nim`: `parseTelemetryConfig` reads the `[Telemetry]` configuration
  section. It supports no authentication, Basic authentication, or a bearer
  token, plus `continue` and `fail` failure policies.
- `main.nim`: `initializeTelemetry`, `startSpan`/`endSpan`, `withSpan`,
  `flushTelemetry`, and `shutdownTelemetry`. Active span nesting is
  thread-local; completed spans are queued under a lock. Ending a span exports
  its summary log synchronously. Flushing exports queued traces; shutdown
  flushes and disables telemetry. `fatalExitCallback` connects fatal logging
  to a failed span summary.
- `protobuf.nim`: encodes trace and log export requests directly as protobuf.
- `exporter.nim`: builds and sends OTLP/HTTP protobuf POST requests to
  `/v1/traces` and `/v1/logs`. `TelemetryTransport` permits injected transports
  in tests. This is HTTP, not gRPC, even though the default endpoint is
  `localhost:4317`.

## Configuration and behavior

The main settings are `enabled`, `endpoint`, `tls`, `timeoutMs`, `failurePolicy`,
`authType`, `username`, `password`, `bearerToken`, and optional `buildId`.
The `tls` setting selects HTTP or HTTPS; HTTPS requires a build with SSL support.
HTTP redirects are disabled. Under the default `continue` policy, export
failures warn rather than abort, and summary-log requests use a 2000 ms timeout.
The `fail` policy can raise `TelemetryRuntimeError`. Failed trace batches are
not retained for retry.

Attribute keys are allowlisted. Error types and fatal messages have dedicated
sanitizers, but this is not general-purpose redaction of all attribute values.
Callers must not place secrets in span names or permitted attributes.
