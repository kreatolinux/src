import std/unittest
import ../../jumpstart/unitname

suite "Jumpstart unit names":
  test "bare and kg names normalize to the definition name":
    check normalizeUnitName("getty-tty1") == "getty-tty1"
    check normalizeUnitName("getty-tty1.kg") == "getty-tty1"

  test "legacy suffixes remain accepted":
    check normalizeUnitName("getty-tty1.service") == "getty-tty1"
    check normalizeUnitName("data.mount") == "data"
    check normalizeUnitName("cleanup.timer") == "cleanup"

  test "sub-unit qualifiers are preserved":
    check normalizeUnitName("example.kg::worker") == "example::worker"
    check unitBaseName("example.service::worker") == "example"
