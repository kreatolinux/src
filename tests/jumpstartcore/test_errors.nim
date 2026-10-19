import std/[strutils, unittest]
import jumpstartcore/errors

suite "core error model":
  test "all codes have canonical names and round trip":
    check ord(high(CoreErrorCode)) + 1 == 28
    for code in CoreErrorCode:
      check errorName(code).startsWith("E_")
      check parseErrorCode(errorName(code)) == code
    expect ValueError: discard parseErrorCode("E_UNKNOWN")

  test "exit status mapping is exhaustive":
    for code in CoreErrorCode:
      let expected = case code
        of ecUsage: 2
        of ecUnsupported: 3
        of ecTimeout, ecCancelled: 4
        else: 1
      check exitCode(code) == expected

  test "diagnostics support global and core forms":
    check diagnostic(ecNotFound, "unit missing") ==
      "jumpctl: E_NOT_FOUND: unit missing"
    check diagnostic(ecBackend, "adapter failed", "systemd") ==
      "jumpctl: systemd: E_BACKEND: adapter failed"

  test "diagnostics cannot inject extra lines":
    check diagnostic(ecIo, "first\nsecond\rthird") ==
      "jumpctl: E_IO: first second third"

  test "typed errors retain code core and message":
    let error = newCoreError(ecTimeout, "too slow", "openrc")
    check error.code == ecTimeout
    check error.core == "openrc"
    check error.msg == "too slow"
    check diagnostic(error[]) == "jumpctl: openrc: E_TIMEOUT: too slow"

suite "error codes supplied by backends":
  test "Kongue fail maps undefined codes to E_BACKEND (§16.3)":
    check kongueFailCode("E_UNIT_STATE") == ecUnitState
    check kongueFailCode("E_NOT_A_CODE") == ecBackend
    check kongueFailCode("") == ecBackend

  test "adapter responses map undefined codes to E_PROTOCOL":
    check backendReportedCode("E_CANCELLED") == ecCancelled
    check backendReportedCode("E_TIMEOUT") == ecTimeout
    check backendReportedCode("BOGUS") == ecProtocol
    check isErrorCodeName("E_IO")
    check not isErrorCodeName("e_io")
