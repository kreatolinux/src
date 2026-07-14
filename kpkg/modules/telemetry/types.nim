import std/tables

type
  TelemetryAuthType* = enum
    telemetryAuthNone
    telemetryAuthBasic
    telemetryAuthBearer

  TelemetryFailurePolicy* = enum
    telemetryContinue
    telemetryFail

  TelemetryConfigError* = object of CatchableError
  TelemetryRuntimeError* = object of CatchableError

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

  TelemetrySettings* = object
    enabled*: bool
    endpoint*: string
    tls*: bool
    timeoutMs*: int
    failurePolicy*: TelemetryFailurePolicy
    authType*: TelemetryAuthType
    username*: string
    password*: string
    bearerToken*: string

const safeAttributes* = [
  "kpkg.command", "kpkg.version", "host.name", "kpkg.target",
  "package.name", "package.version", "package.repository",
  "package.bootstrap", "package.cache_hit", "source.kind",
  "source.filename", "error.type"
]

proc isSafeAttribute*(key: string): bool =
  key in safeAttributes
