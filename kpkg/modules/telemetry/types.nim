type
  TelemetryAuthType* = enum
    telemetryAuthNone
    telemetryAuthBasic
    telemetryAuthBearer

  TelemetryFailurePolicy* = enum
    telemetryContinue
    telemetryFail

  TelemetryConfigError* = object of CatchableError

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
