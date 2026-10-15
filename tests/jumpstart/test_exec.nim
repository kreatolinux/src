import std/[osproc, unittest]
import ../../jumpstart/exec

suite "jumpstart process execution":
  test "services inherit the init terminal":
    check poParentStreams in serviceProcessOptions
    check poDaemon in serviceProcessOptions
    check poUsePath in serviceProcessOptions
