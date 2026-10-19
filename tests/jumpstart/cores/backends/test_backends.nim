import std/[json, tables, times, unittest]
import ../../../../jumpstart/cores/backends/backends, ../../../../jumpstart/cores/lifecycle/dispatch
import jumpstartcore/[errors, protocol]

proc execOperation(mode = emOneshot): PlannedOperation =
  PlannedOperation(core: "demo", operation: "service.start",
    backend: ResolvedBackend(kind: bkExec, timeoutMs: 2_000,
      executable: "bin/adapter", arguments: @["--literal", "$(no-shell)"],
      workingDirectory: "/", execMode: mode,
      environment: initTable[string, string]()))

proc request(): BackendRequest =
  BackendRequest(id: "r1", operation: "service.start", unit: "sshd",
    args: newJObject(), deadline: "2026-10-16T12:00:30Z")

proc opener(path: string): ExecutableDescriptor =
  verifiedExecutable(42, path)

suite "executable backend runner interfaces":
  test "exec plans preserve argv and verified descriptor execution":
    let plan = planExecInvocation(execOperation(), "/cores/demo", "system",
      "1.3.0", "control", @["service.start"], request(), opener)
    check plan.kind == ikOneshotAdapter
    check descriptorHandle(plan.spawn.executable) == 42
    check plan.spawn.argv == @[
      "/cores/demo/bin/adapter", "--literal", "$(no-shell)"]
    check plan.spawn.newSession
    check plan.spawn.protocolDescriptors
    check plan.handshakeTimeoutMs == 2_000

  test "path and descriptor policy reject escapes and stale descriptors":
    for path in ["adapter", "lib/adapter", "bin/../adapter", "/bin/adapter"]:
      expect BackendError:
        discard executablePath("/cores/demo", path)
    expect BackendError:
      discard openCoreExecutable("/cores/demo", "bin/adapter",
        proc(path: string): ExecutableDescriptor =
          verifiedExecutable(1, path, ownerExecutable = false))

  test "fake executor drives handshake response and result validation":
    let plan = planExecInvocation(execOperation(), "/cores/demo", "system",
      "1.3.0", "control", @["service.start"], request(), opener)
    let answer = runBackend(plan,
      proc(p: ExecutionPlan): ExecutorOutcome =
        check p.requestMessage.id == "r1"
        ExecutorOutcome(status: esCompleted, lines: @[
          encodeLine(helloReply(crAdapter, @["service.start"])),
          encodeLine(okResponse("r1", %*{"state": "active"}))]),
      validateResult = proc(operation: string; value: JsonNode): bool =
        operation == "service.start" and value["state"].getStr == "active")
    check answer.value["state"].getStr == "active"

  test "timeout escalates oneshot and persistent differently":
    var actions: seq[EscalationKind]
    proc fakeEscalator(plan: ExecutionPlan; action: Escalation): bool =
      actions.add action.kind
      false
    let oneshot = planExecInvocation(execOperation(), "/cores/demo", "system",
      "1", "control", @["service.start"], request(), opener)
    expect BackendError:
      discard runBackend(oneshot,
        proc(p: ExecutionPlan): ExecutorOutcome =
          ExecutorOutcome(status: esTimedOut), fakeEscalator)
    check actions == @[ekTerminateProcessGroup, ekKillProcessGroup]
    actions.setLen(0)
    let persistent = planExecInvocation(execOperation(emPersistent),
      "/cores/demo", "system", "1", "control", @["service.start"],
      request(), opener)
    expect BackendError:
      discard runBackend(persistent,
        proc(p: ExecutionPlan): ExecutorOutcome =
          ExecutorOutcome(status: esCancelled), fakeEscalator)
    check actions == @[ekCancelRequest, ekKillPersistentAdapter]

  test "custom invocation selects runner role and handler":
    var backend = ResolvedBackend(kind: bkCustom, timeoutMs: 500,
      handler: "start service", workingDirectory: "/",
      environment: initTable[string, string]())
    let operation = PlannedOperation(core: "demo", operation: "service.start",
      backend: backend)
    let plan = planCustomInvocation(operation,
      verifiedExecutable(9, DefaultKongueRunner), "user", "1", "control",
      request())
    check plan.kind == ikCustomRunner
    check plan.offer.role == crRunner
    check plan.requestMessage.function == "start service"

proc answering(lines: seq[string]): Executor =
  result = proc(p: ExecutionPlan): ExecutorOutcome =
    ExecutorOutcome(status: esCompleted, lines: lines)

proc failureCode(plan: ExecutionPlan; executor: Executor): CoreErrorCode =
  try:
    discard runBackend(plan, executor)
    raise newException(AssertionDefect, "backend unexpectedly succeeded")
  except CoreError as e:
    e.code

suite "backend error propagation (§17.3, §18)":
  let plan = planExecInvocation(execOperation(), "/cores/demo", "system",
    "1.3.0", "control", @["service.start"], request(), opener)
  let hello = encodeLine(helloReply(crAdapter, @["service.start"]))

  test "timeouts and cancellations are E_TIMEOUT and E_CANCELLED":
    check failureCode(plan, proc(p: ExecutionPlan): ExecutorOutcome =
      ExecutorOutcome(status: esTimedOut)) == ecTimeout
    check failureCode(plan, proc(p: ExecutionPlan): ExecutorOutcome =
      ExecutorOutcome(status: esCancelled)) == ecCancelled
    check failureCode(plan, proc(p: ExecutionPlan): ExecutorOutcome =
      ExecutorOutcome(status: esCompleted, exitedBeforeResponse: true)) == ecBackend

  test "adapter-supplied codes are preserved; undefined codes are E_PROTOCOL":
    check failureCode(plan, answering(@[hello,
      encodeLine(errorResponse("r1", "E_UNIT_STATE", "not loaded"))])) == ecUnitState
    check failureCode(plan, answering(@[hello,
      encodeLine(errorResponse("r1", "E_CANCELLED", "cancelled"))])) == ecCancelled
    check failureCode(plan, answering(@[hello,
      encodeLine(errorResponse("r1", "E_MADE_UP", "?"))])) == ecProtocol

  test "results are validated against the registry":
    check failureCode(plan, answering(@[hello,
      encodeLine(okResponse("r1", %*{"state": "active", "extra": 1}))])) == ecProtocol
    check failureCode(plan, answering(@[hello,
      encodeLine(okResponse("r1", newJObject()))])) == ecProtocol
    check failureCode(plan, answering(@[hello,
      encodeLine(okResponse("r1", %*{"state": "running"}))])) == ecProtocol
    check runBackend(plan, answering(@[hello,
      encodeLine(okResponse("r1", %*{"state": "active"}))])).value["state"].getStr == "active"

  test "protocol violations are E_PROTOCOL":
    check failureCode(plan, answering(@[
      encodeLine(helloReply(crAdapter, @["service.stop"])),
      encodeLine(okResponse("r1", %*{"state": "active"}))])) == ecProtocol
    check failureCode(plan, answering(@[hello, "{not json"])) == ecProtocol

  test "deadlines go on the wire as RFC 3339":
    check plan.requestMessage.deadline == "2026-10-16T12:00:30Z"
    var epoch = request()
    epoch.deadline = "1792152030.5"
    let converted = planExecInvocation(execOperation(), "/cores/demo", "system",
      "1.3.0", "control", @["service.start"], epoch, opener)
    check validDeadline(converted.requestMessage.deadline)
    check parseDeadline(converted.requestMessage.deadline).toUnix == 1792152030
    var bad = request()
    bad.deadline = "soon"
    try:
      discard planExecInvocation(execOperation(), "/cores/demo", "system",
        "1.3.0", "control", @["service.start"], bad, opener)
      check false
    except BackendError as e:
      check e.kind == beInvalidPlan
