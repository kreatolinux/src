import unittest, parsecfg, strutils, os
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
    let input = """
[Telemetry]
endpoint=collector:4317
password=secret
bearerToken=token

[Options]
cc=gcc
password=ordinary
bearerToken=ordinary-token
"""
    let output = kpkgconfig.redactTelemetrySecrets(input)
    check "password=REDACTED" in output
    check "bearerToken=REDACTED" in output
    check "password=secret" notin output
    check "bearerToken=token" notin output
    check "endpoint=collector:4317" in output
    check "password=ordinary" in output
    check "bearerToken=ordinary-token" in output
    check input.contains("password=secret")
    check input.contains("bearerToken=token")

  test "protects a configuration file with root-only permissions":
    let path = getTempDir() / "kpkg-telemetry-permissions-test.conf"
    defer: removeFile(path)
    writeFile(path, "test")
    kpkgconfig.protectConfigFile(path)
    check getFilePermissions(path) == {fpUserRead, fpUserWrite}
