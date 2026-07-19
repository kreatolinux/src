import base64
import parsecfg
import strutils
import ./types

export types

proc configError(message: string) {.noreturn.} =
  raise newException(TelemetryConfigError, message)

proc parseBoolSetting(value, key: string): bool =
  try:
    result = parseBool(value)
  except ValueError:
    configError("Invalid telemetry " & key)

proc parseFailurePolicy(value: string): TelemetryFailurePolicy =
  case value.toLowerAscii()
  of "continue": telemetryContinue
  of "fail": telemetryFail
  else: configError("Invalid telemetry failure policy")

proc parseAuthType(value: string): TelemetryAuthType =
  case value.toLowerAscii()
  of "none": telemetryAuthNone
  of "basic": telemetryAuthBasic
  of "bearer": telemetryAuthBearer
  else: configError("Invalid telemetry authentication type")

proc parseTelemetryConfig*(cfg: Config): TelemetrySettings =
  result.enabled = parseBoolSetting(cfg.getSectionValue("Telemetry", "enabled", "false"), "enabled")
  result.endpoint = cfg.getSectionValue("Telemetry", "endpoint", "localhost:4317")
  result.tls = parseBoolSetting(cfg.getSectionValue("Telemetry", "tls", "false"), "tls")
  try:
    result.timeoutMs = parseInt(cfg.getSectionValue("Telemetry", "timeoutMs", "5000"))
  except ValueError:
    configError("Invalid telemetry timeout")
  result.failurePolicy = parseFailurePolicy(cfg.getSectionValue("Telemetry", "failurePolicy", "continue"))
  result.authType = parseAuthType(cfg.getSectionValue("Telemetry", "authType", "none"))
  result.username = cfg.getSectionValue("Telemetry", "username", "")
  result.password = cfg.getSectionValue("Telemetry", "password", "")
  result.bearerToken = cfg.getSectionValue("Telemetry", "bearerToken", "")
  result.buildId = sanitizeBuildId(cfg.getSectionValue("Telemetry", "buildId", ""))

  if not result.enabled:
    return
  if result.endpoint.strip().len == 0:
    configError("Telemetry endpoint cannot be empty")
  if result.timeoutMs <= 0:
    configError("Telemetry timeout must be positive")
  case result.authType
  of telemetryAuthBasic:
    if result.username.len == 0 or result.password.len == 0:
      configError("Telemetry basic authentication requires credentials")
  of telemetryAuthBearer:
    if result.bearerToken.len == 0:
      configError("Telemetry bearer authentication requires a token")
  of telemetryAuthNone:
    discard

proc authorizationHeader*(settings: TelemetrySettings): string =
  case settings.authType
  of telemetryAuthBasic:
    "Basic " & encode(settings.username & ":" & settings.password)
  of telemetryAuthBearer:
    "Bearer " & settings.bearerToken
  of telemetryAuthNone:
    ""
