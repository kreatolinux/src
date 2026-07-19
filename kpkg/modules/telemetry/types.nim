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

  LogRecord* = ref object
    traceId*: string
    spanId*: string
    timestampNs*: int64
    body*: string
    status*: SpanStatus
    attributes*: Table[string, string]

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
    buildId*: string

const safeAttributes* = [
  "kpkg.command", "kpkg.version", "host.name", "kpkg.target",
  "package.name", "package.version", "package.repository",
  "package.bootstrap", "package.cache_hit", "source.kind",
  "source.filename", "error.type", "process.exit_code", "run3.stage",
  "command.kind", "kpkg.build.id"
]

proc isSafeAttribute*(key: string): bool =
  key in safeAttributes

proc isSafeLogAttribute*(key: string): bool =
  key in safeAttributes or key in ["span.parent_id", "span.duration_ns",
      "span.status", "error.message"]

const buildIdMaxLength = 128

proc sanitizeBuildId*(value: string): string =
  ## Returns the build ID if it is safe to export, otherwise "".
  if value.len == 0 or value.len > buildIdMaxLength:
    return ""
  for character in value:
    if character notin {'A'..'Z', 'a'..'z', '0'..'9', '.', '_', ':', '-'}:
      return ""
  value

proc sanitizeCommandName*(name: string): string =
  ## Returns a CLI subcommand name safe for telemetry, or "unknown".
  if name.len == 0 or name.len > 32:
    return "unknown"
  for character in name:
    if character notin {'a'..'z', '0'..'9'}:
      return "unknown"
  name
