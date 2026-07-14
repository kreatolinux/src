import unittest, parsecfg, strutils
import ../../kpkg/modules/telemetry/config
import ../../kpkg/modules/config as kpkgconfig

suite "telemetry configuration":
  test "defaults disable telemetry":
    var cfg = newConfig()
    let settings = parseTelemetryConfig(cfg)
    check not settings.enabled
    check settings.endpoint == "localhost:4317"
    check not settings.tls
    check settings.timeoutMs == 5000
    check settings.failurePolicy == telemetryContinue
    check settings.authType == telemetryAuthNone
    check settings.username == ""
    check settings.password == ""
    check settings.bearerToken == ""

  test "basic authentication requires both credentials":
    var cfg = newConfig()
    cfg.setSectionKey("Telemetry", "enabled", "true")
    cfg.setSectionKey("Telemetry", "authType", "basic")
    cfg.setSectionKey("Telemetry", "username", "12345")
    expect TelemetryConfigError:
      discard parseTelemetryConfig(cfg)

  test "basic authentication requires a username":
    var cfg = newConfig()
    cfg.setSectionKey("Telemetry", "enabled", "true")
    cfg.setSectionKey("Telemetry", "authType", "basic")
    cfg.setSectionKey("Telemetry", "password", "secret")
    expect TelemetryConfigError:
      discard parseTelemetryConfig(cfg)

  test "bearer authentication produces authorization metadata":
    var cfg = newConfig()
    cfg.setSectionKey("Telemetry", "authType", "bearer")
    cfg.setSectionKey("Telemetry", "bearerToken", "secret")
    check parseTelemetryConfig(cfg).authorizationHeader == "Bearer secret"

  test "bearer authentication requires a token":
    var cfg = newConfig()
    cfg.setSectionKey("Telemetry", "enabled", "true")
    cfg.setSectionKey("Telemetry", "authType", "bearer")
    expect TelemetryConfigError:
      discard parseTelemetryConfig(cfg)

  test "redacts telemetry credentials in configuration output":
    let output = kpkgconfig.redactTelemetrySecrets("""
[Telemetry]
endpoint=collector.example:4317
password=top-secret
bearerToken=token-secret

[Options]
cc=gcc
""")
    check "password=REDACTED" in output
    check "bearerToken=REDACTED" in output
    check "top-secret" notin output
    check "token-secret" notin output
    check "endpoint=collector.example:4317" in output
