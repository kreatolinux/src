import std/[options, strutils, unittest]
import ../../../../jumpstart/cores/backends/supervisor, ../../../../jumpstart/cores/manifest/types

suite "process-independent supervisor model":
  test "handshake is strict and deadline bounded":
    var model = initSupervisor("demo", 100, 30)
    check model.helloLine("system", "1.3.0").contains("\"role\":\"supervisor\"")
    expect SupervisorProtocolError:
      model.acceptHandshake("""{"type":"hello","protocol":"jumpstart-core/1","role":"supervisor"}""", 130)
    model = initSupervisor("demo", 100, 30)
    model.acceptHandshake("""{"type":"hello","protocol":"jumpstart-core/1","role":"supervisor"}""", 129)
    check model.phase == spRunning

  test "exit degrades only a loaded core and never requests restart":
    var model = initSupervisor("demo", 0, 10)
    model.acceptHandshake("""{"type":"hello","protocol":"jumpstart-core/1","role":"supervisor"}""", 1)
    var core = CoreRuntime(name: "demo", state: csLoaded)
    check model.observeExit(core, "status 9") == setDegraded
    check core.state == csDegraded and core.failure == "status 9"

  test "unload closes input, terms, waits ten seconds, then kills once":
    var model = initSupervisor("demo", 0, 10)
    model.acceptHandshake("""{"type":"hello","protocol":"jumpstart-core/1","role":"supervisor"}""", 1)
    check model.beginUnload(50) == @[saCloseDescriptor3, saSendTerm]
    check model.continueUnload(10049).len == 0
    check model.continueUnload(10050) == @[saSendKill]
    check model.continueUnload(20000).len == 0
    var core = CoreRuntime(name: "demo", state: csLoaded)
    check model.observeExit(core) == setUnchanged
    check core.state == csLoaded

  test "notifications preserve last known states and are rate limited":
    var model = initSupervisor("demo", 0, 10)
    model.acceptHandshake("""{"type":"hello","protocol":"jumpstart-core/1","role":"supervisor"}""", 1)
    check model.receiveNotification("""{"type":"notify","unit":"a.service","state":"active"}""", 2) == ndRecorded
    check model.receiveNotification("""{"type":"notify","unit":"a.service","state":"failed","detail":"boom"}""", 3) == ndRecorded
    let known = model.lastKnown("a.service")
    check known.isSome and known.get.state == rusFailed and known.get.detail == "boom"
    for i in 3 .. 100:
      check model.receiveNotification("""{"type":"notify","unit":"b.service","state":"inactive"}""", 4) == ndRecorded
    check model.receiveNotification("""{"type":"notify","unit":"a.service","state":"active"}""", 999) == ndRateLimited
    check model.lastKnown("a.service").get.state == rusFailed
    check model.notificationDrops == 1
    check model.receiveNotification("""{"type":"notify","unit":"a.service","state":"active"}""", 1002) == ndRecorded

  test "unknown notifications require a useful detail":
    var model = initSupervisor("demo", 0, 10)
    model.acceptHandshake("""{"type":"hello","protocol":"jumpstart-core/1","role":"supervisor"}""", 1)
    expect SupervisorProtocolError:
      discard model.receiveNotification("""{"type":"notify","unit":"a","state":"unknown"}""", 2)
