import std/[strutils, unittest]
import ../../../../jumpstart/cores/lifecycle/resources

suite "core resource accounting":
  test "operation limits queue or reject as specified":
    var state: ResourceAccounting
    for i in 1 .. MaxMutatingOperations: check state.admit(ocMutating).kind == akAdmitted
    let first = state.admit(ocMutating)
    let second = state.admit(ocMutating)
    check first.kind == akQueued and second.kind == akQueued
    check state.release(ocMutating).ticket == first.ticket
    check state.release(ocMutating).ticket == second.ticket
    for i in 1 .. MaxReadOperations: check state.admit(ocReadOnly).kind == akAdmitted
    check state.admit(ocReadOnly).kind == akRejected

  test "connections and notification windows are bounded":
    var state: ResourceAccounting
    for i in 1 .. MaxSocketConnections: check state.openConnection()
    check not state.openConnection()
    state.closeConnection(); check state.openConnection()
    var notifications: NotificationWindow
    for i in 1 .. MaxNotificationsPerSecond: check notifications.allowNotification(0)
    check not notifications.allowNotification(999)
    check notifications.allowNotification(1000)
    check notifications.dropped == 1

  test "ring drops oldest lines and retains a loss marker":
    var ring = initLogRing(50)
    ring.addLine("1111111111\n")
    ring.addLine("2222222222\n")
    ring.addLine("3333333333\n")
    ring.addLine("4444444444\n")
    ring.addLine("5555555555\n")
    check ring.bufferedBytes <= 50
    check ring.dropped > 0
    check ring.snapshot[0].contains("dropped")
    check ring.snapshot[^1] == "5555555555\n"
    ring.clear(); check ring.bufferedLines == 0 and ring.dropped == 0

  test "log write retry is deterministic":
    var retry = initLogRetryState()
    check not retry.shouldTryWrite(0)
    retry.markFilesystemsReady(10)
    check retry.shouldTryWrite(10)
    retry.writeFailed(10)
    check not retry.shouldTryWrite(60009)
    check retry.shouldTryWrite(60010)
    retry.writeSucceeded()
    check retry.shouldTryWrite(60011)

suite "resource classes and abandoned waiters":
  test "unit.resolve has its own queued 256-slot class":
    check classify("unit.resolve", false) == ocResolve
    check classify("service.start", true) == ocMutating
    check classify("log.follow", false) == ocReadOnly
    var state: ResourceAccounting
    for i in 1 .. MaxReadOperations: check state.admit(ocReadOnly).kind == akAdmitted
    for i in 1 .. MaxResolveOperations: check state.admit(ocResolve).kind == akAdmitted
    check state.admit(ocResolve).kind == akQueued
    check state.admit(ocReadOnly).kind == akRejected

  test "a cancelled ticket is never promoted":
    var state: ResourceAccounting
    for i in 1 .. MaxMutatingOperations: discard state.admit(ocMutating)
    let gone = state.admit(ocMutating)
    let next = state.admit(ocMutating)
    check state.isQueued(ocMutating, gone.ticket)
    check state.cancelQueued(ocMutating, gone.ticket)
    check not state.cancelQueued(ocMutating, gone.ticket)
    check state.release(ocMutating).ticket == next.ticket
    check state.mutatingInFlight == MaxMutatingOperations
    check state.release(ocMutating).kind == akRejected
    check state.mutatingInFlight == MaxMutatingOperations - 1
