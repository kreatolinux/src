import std/[osproc, unittest]
import ../../jumpstart/exec

suite "jumpstart process execution":
  test "regular services remain detached from the init terminal":
    let options = processOptionsForService(false)
    check poUsePath in options
    check poDaemon in options
    check poParentStreams notin options

  test "terminal services inherit the init terminal":
    let options = processOptionsForService(true)
    check poUsePath in options
    check poParentStreams in options
    check poDaemon notin options
