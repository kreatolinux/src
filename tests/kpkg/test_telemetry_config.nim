import unittest, parsecfg
import ../../kpkg/modules/telemetry/config

suite "telemetry configuration":
  test "defaults disable telemetry":
    var cfg = newConfig()
    let settings = parseTelemetryConfig(cfg)
    check not settings.enabled
    check settings.endpoint == "localhost:4317"
    check settings.authType == telemetryAuthNone

  test "basic authentication requires both credentials":
    var cfg = newConfig()
    cfg.setSectionKey("Telemetry", "enabled", "true")
    cfg.setSectionKey("Telemetry", "authType", "basic")
    cfg.setSectionKey("Telemetry", "username", "12345")
    expect TelemetryConfigError:
      discard parseTelemetryConfig(cfg)

  test "bearer authentication produces authorization metadata":
    var cfg = newConfig()
    cfg.setSectionKey("Telemetry", "authType", "bearer")
    cfg.setSectionKey("Telemetry", "bearerToken", "secret")
    check parseTelemetryConfig(cfg).authorizationHeader == "Bearer secret"
