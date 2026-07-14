import unittest, strutils
import ../../kpkg/commands/repl

suite "REPL telemetry configuration display":
  test "config Telemetry redacts every telemetry secret":
    let output = displayConfigQuery("Telemetry", "", """
endpoint=collector.example:4318
password=secret
bearerToken=token
""")

    check "secret" notin output
    check "token" notin output
    check "password=REDACTED" in output
    check "bearerToken=REDACTED" in output

  test "config Telemetry password and bearerToken redact direct values":
    check displayConfigQuery("Telemetry", "password", "secret") == "REDACTED"
    check displayConfigQuery("Telemetry", "bearerToken", "token") == "REDACTED"
