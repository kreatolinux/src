import std/[strutils, unittest]
import ../../../../jumpstart/cores/lifecycle/[resources, runtime_resources]

suite "runtime resource coordinator":
  test "per-core operation queues are isolated and promote FIFO":
    var runtime = initRuntimeResources()
    for i in 1 .. MaxMutatingOperations:
      check runtime.admitOperation("a", ocMutating).admission.kind == akAdmitted
    let a1 = runtime.admitOperation("a", ocMutating).admission
    let a2 = runtime.admitOperation("a", ocMutating).admission
    check a1.kind == akQueued and a2.kind == akQueued
    check runtime.admitOperation("b", ocMutating).admission.kind == akAdmitted
    check runtime.coreQueued("a", ocMutating) == 2
    check runtime.coreQueued("b", ocMutating) == 0
    check runtime.completeOperation("a", ocMutating).admission.ticket == a1.ticket
    check runtime.completeOperation("a", ocMutating).admission.ticket == a2.ticket

  test "daemon connections reject at the limit and recover on close":
    var runtime = initRuntimeResources()
    for i in 1 .. MaxSocketConnections:
      check runtime.acceptConnection() == caAccepted
    check runtime.connectionCount == MaxSocketConnections
    check runtime.acceptConnection() == caLimit
    runtime.closeConnection()
    check runtime.acceptConnection() == caAccepted

  test "notification accounting is per process and removable":
    var runtime = initRuntimeResources()
    for i in 1 .. MaxNotificationsPerSecond:
      check runtime.receiveNotification("pid:1", 0).accepted
    let dropped = runtime.receiveNotification("pid:1", 999)
    check not dropped.accepted and dropped.droppedTotal == 1
    check runtime.receiveNotification("pid:2", 999).accepted
    runtime.forgetProcess("pid:1")
    check runtime.notificationProcessCount == 1
    check runtime.receiveNotification("pid:1", 999).accepted

  test "early and failed logs remain buffered until successful flush":
    var runtime = initRuntimeResources(logCapacity = 80)
    check runtime.planLogWrite("early\n", 0).lines.len == 0
    runtime.filesystemsReady(10)
    let initial = runtime.planLogWrite("ready\n", 10)
    check initial.lines == @["early\n", "ready\n"]
    runtime.finishLogWrite(initial, false, 10)
    check runtime.planLogWrite("during retry\n", 60_009).lines.len == 0
    let retry = runtime.planLogWrite("retry\n", 60_010)
    check retry.lines[^1] == "retry\n"
    check retry.lines.join.contains("early")
    runtime.finishLogWrite(retry, true, 60_010)
    check runtime.pendingLogLines.len == 0
    let direct = runtime.planLogWrite("direct\n", 60_011)
    check direct.lines == @["direct\n"]
    runtime.finishLogWrite(direct, true, 60_011)

  test "bounded coordinator log plan exposes dropped marker":
    var runtime = initRuntimeResources(logCapacity = 50)
    for i in 1 .. 10:
      discard runtime.planLogWrite("0123456789\n", 0)
    runtime.filesystemsReady(1)
    let plan = runtime.planLogWrite("last\n", 1)
    check plan.lines[0].contains("dropped")
    check plan.lines[^1] == "last\n"

suite "runtime coordinator waiters and cores":
  test "withdrawn waiters and unloaded cores":
    var runtime = initRuntimeResources()
    for i in 1 .. MaxResolveOperations:
      discard runtime.admitOperation("a", ocResolve)
    let waiter = runtime.admitOperation("a", ocResolve).admission
    check waiter.kind == akQueued
    check runtime.ticketQueued("a", ocResolve, waiter.ticket)
    check runtime.cancelQueuedOperation("a", ocResolve, waiter.ticket)
    check runtime.completeOperation("a", ocResolve).admission.kind == akRejected
    check not runtime.forgetCore("a")
    for i in 2 .. MaxResolveOperations:
      discard runtime.completeOperation("a", ocResolve)
    check runtime.forgetCore("a")
    check runtime.coreInFlight("a", ocResolve) == 0
