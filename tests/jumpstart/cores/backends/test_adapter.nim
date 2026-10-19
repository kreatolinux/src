import std/[json, unittest]
import ../../../../jumpstart/cores/backends/adapter
import jumpstartcore/[errors, protocol]

proc req(id: string): ProtocolMessage =
  request(id, "service.start", "web", newJObject(), "2030-01-01T00:00:00Z")

proc kinds(actions: seq[AdapterAction]): seq[AdapterActionKind] =
  ## Effects, ignoring lock-release bookkeeping (checked separately).
  for action in actions:
    if action.kind != aaSettled: result.add action.kind

proc effects(actions: seq[AdapterAction]): seq[AdapterAction] =
  for action in actions:
    if action.kind != aaSettled: result.add action

proc settled(actions: seq[AdapterAction]): seq[string] =
  for action in actions:
    if action.kind == aaSettled: result.add action.requestId

proc ready(manager: var AdapterManager; name = "a"; now = 1'i64): seq[AdapterAction] =
  manager.receive(name, helloReply(crAdapter, @["service.start"]), now)

suite "adapter manager state machine":
  test "persistent handshake gates and multiplexes requests":
    var manager = initAdapterManager("system", "1.3.0")
    manager.registerPersistent("a", "demo", ["service.start"])
    check manager.startPersistent("a", 0).kinds == @[aaStart, aaSend]
    check manager.requestPersistent("a", req("one"), 1).len == 0
    check manager.requestPersistent("a", req("two"), 1).len == 0
    check manager.ready().kinds == @[aaSend, aaSend]
    check manager.inFlight("a") == @["one", "two"]
    let completed = manager.receive("a",
      okResponse("two", %*{"state": "active"}), 2)
    check completed.kinds == @[aaResponse]
    check manager.inFlight("a") == @["one"]

  test "handshake mismatch fails all inflight requests as protocol":
    var manager = initAdapterManager("system", "1.3.0")
    manager.registerPersistent("a", "demo", ["service.start"])
    discard manager.startPersistent("a", 0)
    discard manager.requestPersistent("a", req("one"), 1)
    let actions = manager.receive("a",
      helloReply(crAdapter, @["service.stop"]), 2)
    check actions.kinds == @[aaFailure, aaTerminateGroup]
    check actions[0].errorCode == ecProtocol

  test "persistent cancellation sends cancel then kills and restarts lazily":
    var manager = initAdapterManager("system", "1.3.0")
    manager.registerPersistent("a", "demo", ["service.start"])
    discard manager.startPersistent("a", 0); discard manager.ready()
    discard manager.requestPersistent("a", req("one"), 2)
    check manager.cancel("one", 10).kinds == @[aaSend]
    let expired = manager.advance(5_010)
    check expired.kinds == @[aaKillGroup, aaFailure]
    check expired[1].errorCode == ecCancelled
    discard manager.processExited("a", 137, 5_011)
    check manager.requestPersistent("a", req("two"), 5_012).kinds ==
      @[aaStart, aaSend]

  test "unexpected exit fails every in-flight id with backend":
    var manager = initAdapterManager("system", "1.3.0")
    manager.registerPersistent("a", "demo", ["service.start"])
    discard manager.startPersistent("a", 0); discard manager.ready()
    discard manager.requestPersistent("a", req("one"), 2)
    discard manager.requestPersistent("a", req("two"), 2)
    let actions = manager.processExited("a", 1, 3).effects
    check actions.kinds == @[aaFailure, aaFailure]
    check actions[0].errorCode == ecBackend
    check actions[1].errorCode == ecBackend

  test "sixth lazy restart in sixty seconds degrades core":
    var manager = initAdapterManager("system", "1.3.0")
    manager.registerPersistent("a", "demo", ["service.start"])
    discard manager.startPersistent("a", 0)
    for i in 0 ..< 5:
      discard manager.processExited("a", 1, int64(i * 100))
      let actions = manager.requestPersistent("a", req("r" & $i), int64(i * 100 + 1))
      check actions.kinds == @[aaStart, aaSend]
    discard manager.processExited("a", 1, 501)
    let degraded = manager.requestPersistent("a", req("last"), 502).effects
    check degraded.kinds == @[aaDegraded, aaFailure]
    check degraded[^1].errorCode == ecDegraded
    check manager.state("a") == asDegraded

  test "restart history expires after sixty seconds":
    var manager = initAdapterManager("system", "1.3.0")
    manager.registerPersistent("a", "demo", ["service.start"])
    discard manager.startPersistent("a", 0)
    discard manager.processExited("a", 1, 1)
    discard manager.requestPersistent("a", req("one"), 2)
    check manager.restartCount("a", 2) == 1
    check manager.restartCount("a", 60_002) == 0

  test "oneshot closes input after response and escalates after five seconds":
    var manager = initAdapterManager("system", "1.3.0")
    check manager.requestOneshot("tool", "demo", ["service.start"],
      req("one"), 0, 1_000).kinds == @[aaStart, aaSend]
    let handshake = manager.receive("tool#1",
      helloReply(crAdapter, @["service.start"]), 1)
    check handshake.kinds == @[aaSend]
    check manager.receive("tool#1", okResponse("one", newJObject()), 2).kinds ==
      @[aaResponse, aaCloseInput]
    check manager.advance(5_002).kinds == @[aaTerminateGroup]
    check manager.advance(10_002).kinds == @[aaKillGroup]

  test "notification rate is one hundred per rolling one-second bucket":
    var manager = initAdapterManager("system", "1.3.0")
    manager.registerPersistent("a", "demo", ["service.start"])
    discard manager.startPersistent("a", 0); discard manager.ready()
    for i in 0 ..< 100:
      check manager.receive("a", notification("u", "active"), 10).kinds ==
        @[aaNotification]
    check manager.receive("a", notification("u", "active"), 10).kinds ==
      @[aaNotificationDropped]
    check manager.receive("a", notification("u", "active"), 10).len == 0
    check manager.receive("a", notification("u", "active"), 1_010).kinds ==
      @[aaNotification]

  test "known-id malformed messages affect only that request":
    var manager = initAdapterManager("system", "1.3.0")
    manager.registerPersistent("a", "demo", ["service.start"])
    discard manager.startPersistent("a", 0); discard manager.ready()
    discard manager.requestPersistent("a", req("one"), 2)
    discard manager.requestPersistent("a", req("two"), 2)
    let actions = manager.receiveLine("a",
      "{\"type\":\"response\",\"id\":\"one\",\"status\":\"wat\"}\n", 3)
    check actions.kinds == @[aaFailure]
    check actions[0].errorCode == ecProtocol
    check manager.inFlight("a") == @["two"]

suite "deadlines, cancellation and runners":
  test "persistent timeout reports E_TIMEOUT, sends cancel and swallows the late response":
    var manager = initAdapterManager("system", "1.3.0")
    manager.registerPersistent("a", "demo", ["service.start"])
    discard manager.startPersistent("a", 0); discard manager.ready()
    discard manager.requestPersistent("a", req("one"), 10, timeoutMs = 1_000)
    discard manager.requestPersistent("a", req("two"), 10, timeoutMs = 60_000)
    check manager.advance(1_009).len == 0
    let expired = manager.advance(1_010)
    check expired.kinds == @[aaFailure, aaSend]
    check expired[0].errorCode == ecTimeout
    check expired[1].message.kind == pmCancel
    check manager.inFlight("a") == @["one", "two"]  # still occupies the adapter
    let late = manager.receive("a", errorResponse("one", "E_CANCELLED", "stopped"), 1_100)
    check late.kinds == @[aaLog]
    check late.settled == @["one"]
    check manager.inFlight("a") == @["two"]

  test "unacknowledged timeout kills after five seconds without re-reporting":
    var manager = initAdapterManager("system", "1.3.0")
    manager.registerPersistent("a", "demo", ["service.start"])
    discard manager.startPersistent("a", 0); discard manager.ready()
    discard manager.requestPersistent("a", req("one"), 0, timeoutMs = 1_000)
    discard manager.requestPersistent("a", req("two"), 0, timeoutMs = 60_000)
    discard manager.advance(1_000)
    check manager.advance(5_999).len == 0
    let killedRaw = manager.advance(6_000)
    check killedRaw.settled == @["one", "two"]
    let killed = killedRaw.effects
    check killed.kinds == @[aaKillGroup, aaFailure]
    check killed[1].requestId == "two"
    check killed[1].errorCode == ecBackend
    check manager.processExited("a", 137, 6_001).kinds.len == 0

  test "oneshot timeout terminates the group, then kills":
    var manager = initAdapterManager("system", "1.3.0")
    discard manager.requestOneshot("tool", "demo", ["service.start"], req("one"), 0, 1_000)
    discard manager.receive("tool#1", helloReply(crAdapter, @["service.start"]), 1)
    let expired = manager.advance(1_000)
    check expired.kinds == @[aaFailure, aaTerminateGroup]
    check expired[0].errorCode == ecTimeout
    check manager.advance(6_000).kinds == @[aaKillGroup]
    check manager.processExited("tool#1", 137, 6_001).kinds.len == 0

  test "oneshot handshake timeout is E_TIMEOUT":
    var manager = initAdapterManager("system", "1.3.0")
    discard manager.requestOneshot("tool", "demo", ["service.start"], req("one"), 0, 1_000)
    let expired = manager.advance(1_000)
    check expired.kinds[0] == aaFailure
    check expired[0].errorCode == ecTimeout

  test "client cancellation preserves the adapter's E_CANCELLED response":
    var manager = initAdapterManager("system", "1.3.0")
    manager.registerPersistent("a", "demo", ["service.start"])
    discard manager.startPersistent("a", 0); discard manager.ready()
    discard manager.requestPersistent("a", req("one"), 0, timeoutMs = 60_000)
    check manager.cancel("one", 5).kinds == @[aaSend]
    let answered = manager.receive("a", errorResponse("one", "E_CANCELLED", "cancelled"), 6)
    check answered.kinds == @[aaResponse]
    check answered[0].response.error.code == "E_CANCELLED"
    check responseFailure(answered[0].response)[0] == ecCancelled

  test "runners use role runner and declare no operations":
    var manager = initAdapterManager("user", "1.3.0")
    let start = manager.requestRunner("@runner", "demo",
      request("r1", "service.start", "web", newJObject(), "2030-01-01T00:00:00Z", "start_web"),
      0, 1_000)
    check start.kinds == @[aaStart, aaSend]
    check start[1].message.role == crRunner
    check manager.receive("@runner#1", helloReply(crRunner), 1).kinds == @[aaSend]
    var other = initAdapterManager("user", "1.3.0")
    discard other.requestRunner("@runner", "demo",
      request("r2", "service.start", "web", newJObject(), "2030-01-01T00:00:00Z", "start_web"),
      0, 1_000)
    let rejected = other.receive("@runner#1", helloReply(crAdapter, @["service.start"]), 1)
    check rejected.kinds[0] == aaFailure
    check rejected[0].errorCode == ecProtocol
