import std/[options, tables, unittest]
import ../../jumpstart/cores/lifecycle/dispatch

proc info(name: string; operationClass: OperationClass;
          routing = orUnit): OperationInfo =
  var lock = olNone
  if operationClass == ocMutating:
    if name in ["unit.load", "target.isolate"]: lock = olCore
    elif name in ["log.write", "log.rotate", "log.vacuum"]: lock = olLog
    elif name notin ["unit.activate", "unit.deactivate"]: lock = olUnit
  OperationInfo(name: name, operationClass: operationClass,
    routing: routing, lock: lock)

proc terminal(core, operation: string): CoreDispatchPlan =
  result = initCoreDispatchPlan(core)
  result.addOperation(info(operation, ocMutating),
    ResolvedBackend(kind: bkNative))

proc delegated(core, operation, target, targetOperation: string): CoreDispatchPlan =
  result = initCoreDispatchPlan(core)
  result.addOperation(info(operation, ocMutating), ResolvedBackend(
    kind: bkDelegate, delegateCore: target,
    delegateOperation: targetOperation))

suite "core dispatch planning":
  test "duration parsing is exact and capped":
    check parseDurationMs("1ms") == 1
    check parseDurationMs("90s") == 90_000
    check parseDurationMs("24h") == MaxTimeoutMs
    for invalid in ["", "0s", "1", "1d", "25h", "-1s"]:
      expect DispatchError: discard parseDurationMs(invalid)

  test "common and exec defaults are fully resolved":
    var env = initTable[string, string]()
    env["LANG"] = "C"
    let resolved = resolveBackend(info("unit.list", ocReadOnly, orGlobal),
      BackendSpec(kind: bkExec, options: BackendOptions(
        timeout: "10s", sandbox: some(true), executable: "bin/adapter",
        environment: env)), manifestAccount = "daemon")
    check resolved.timeoutMs == 10_000
    check resolved.user == "daemon"
    check resolved.workingDirectory == "/"
    check resolved.execMode == emOneshot
    check resolved.arguments.len == 0
    check resolved.environment["LANG"] == "C"

  test "security options have no hidden defaults":
    expect DispatchError:
      discard resolveBackend(info("unit.list", ocReadOnly, orGlobal),
        BackendSpec(kind: bkCustom, options: BackendOptions(
          timeout: "1s", handler: "list")))
    expect DispatchError:
      discard resolveBackend(info("service.start", ocMutating),
        BackendSpec(kind: bkExec, options: BackendOptions(
          timeout: "1s", sandbox: some(false), executable: "bin/a")))
    expect DispatchError:
      discard resolveBackend(info("unit.list", ocReadOnly, orGlobal),
        BackendSpec(kind: bkExec, options: BackendOptions(
          timeout: "1s", sandbox: some(false), network: true,
          executable: "bin/a")))

  test "option sets are backend-specific":
    expect DispatchError:
      discard resolveBackend(info("service.start", ocMutating),
        BackendSpec(kind: bkUnsupported, options: BackendOptions(timeout: "1s")))
    expect DispatchError:
      discard resolveBackend(info("service.start", ocMutating),
        BackendSpec(kind: bkDelegate, options: BackendOptions(
          delegateCore: "other", timeout: "1s")))
    expect DispatchError:
      discard resolveBackend(info("service.start", ocMutating),
        BackendSpec(kind: bkCustom, options: BackendOptions(
          timeout: "1s", handler: "start", executable: "bin/a")))

  test "delegate defaults operation and enforces subsystem":
    let resolved = resolveBackend(info("service.start", ocMutating),
      BackendSpec(kind: bkDelegate, options: BackendOptions(
        delegateCore: "other")))
    check resolved.delegateOperation == "service.start"
    expect DispatchError:
      discard resolveBackend(info("service.start", ocMutating),
        BackendSpec(kind: bkDelegate, options: BackendOptions(
          delegateCore: "other", delegateOperation: "mount.start")))

  test "unsupported and absent operations never fall back":
    var cores = initTable[string, CoreDispatchPlan]()
    cores["serviceHandler"] = terminal("serviceHandler", "service.start")
    var extension = initCoreDispatchPlan("extension")
    extension.addOperation(info("service.start", ocMutating),
      ResolvedBackend(kind: bkUnsupported))
    cores["extension"] = extension
    try:
      discard resolveDispatch(cores, "extension", "service.start")
      fail()
    except DispatchError as e:
      check e.code == ecUnsupported
    try:
      discard resolveDispatch(cores, "extension", "service.stop")
      fail()
    except DispatchError as e:
      check e.code == ecUnsupported

  test "delegation resolves, rejects cycles, and permits at most four hops":
    var cores = initTable[string, CoreDispatchPlan]()
    for i in 0 .. 3:
      cores[$i] = delegated($i, "service.start", $(i + 1), "service.start")
    cores["4"] = terminal("4", "service.start")
    let plan = resolveDispatch(cores, "0", "service.start")
    check plan.target.core == "4"
    check plan.chain.len == 5
    cores["4"] = delegated("4", "service.start", "5", "service.start")
    cores["5"] = terminal("5", "service.start")
    expect DispatchError: discard resolveDispatch(cores, "0", "service.start")
    cores["4"] = delegated("4", "service.start", "0", "service.start")
    expect DispatchError: validateDelegations(cores)

suite "core dispatch locks and cancellation":
  test "lock classification follows common semantics":
    check selectLock(info("service.status", ocReadOnly), "c", "u").kind == lkNone
    check selectLock(info("log.follow", ocStreaming, orGlobal), "c").kind == lkNone
    check selectLock(info("unit.activate", ocMutating, orGlobal), "c").kind == lkNone
    check selectLock(info("unit.load", ocMutating, orGlobal), "c").kind == lkCore
    check selectLock(info("target.isolate", ocMutating), "c", "t").kind == lkCore
    check selectLock(info("log.rotate", ocMutating), "c").kind == lkLog
    check selectLock(info("service.start", ocMutating), "c", "u").kind == lkUnit

  test "same unit serializes while distinct units run":
    var locks = initLockManager()
    let selection = LockSelection(kind: lkUnit, core: "c", unit: "u")
    let first = locks.acquire(selection, 0, 100)
    let second = locks.acquire(selection, 0, 100)
    let other = locks.acquire(LockSelection(kind: lkUnit, core: "c", unit: "v"), 0, 100)
    check first.state == rsRunning
    check second.state == rsWaiting
    check other.state == rsRunning
    locks.complete(first.id, 1)
    check locks.ticket(second.id).state == rsRunning

  test "core lock is a barrier for unit mutations":
    var locks = initLockManager()
    let unit1 = locks.acquire(LockSelection(kind: lkUnit, core: "c", unit: "u"), 0, 100)
    let whole = locks.acquire(LockSelection(kind: lkCore, core: "c"), 0, 100)
    let unit2 = locks.acquire(LockSelection(kind: lkUnit, core: "c", unit: "v"), 0, 100)
    check locks.ticket(whole.id).state == rsWaiting
    locks.complete(unit1.id, 1)
    check locks.ticket(whole.id).state == rsRunning
    check locks.ticket(unit2.id).state == rsWaiting
    locks.complete(whole.id, 2)
    check locks.ticket(unit2.id).state == rsRunning

  test "waiting timeout needs no process cancellation":
    var locks = initLockManager()
    discard locks.acquire(LockSelection(kind: lkUnit, core: "c", unit: "u"), 0, 100)
    let waiting = locks.acquire(LockSelection(kind: lkUnit, core: "c", unit: "u"), 0, 5)
    check locks.advance(5).len == 0
    check locks.ticket(waiting.id).state == rsTimedOut

  test "timed out operation retains its lock until termination completes":
    var locks = initLockManager()
    let selection = LockSelection(kind: lkUnit, core: "c", unit: "u")
    let running = locks.acquire(selection, 0, 5)
    let waiting = locks.acquire(selection, 0, 100)
    discard locks.advance(5)
    check locks.ticket(waiting.id).state == rsWaiting
    locks.complete(running.id, 6)
    check locks.ticket(waiting.id).state == rsRunning

  test "running timeout plans terminate then kill":
    var locks = initLockManager()
    let running = locks.acquire(LockSelection(kind: lkNone), 1, 10)
    let initial = locks.advance(10)
    check initial == @[(running.id, csTerminateProcessGroup)]
    check locks.ticket(running.id).state == rsTimedOut
    check locks.advance(5_009).len == 0
    check locks.advance(5_010) == @[(running.id, csKillProcessGroup)]
    check locks.advance(20_000).len == 0

  test "persistent cancellation uses protocol then kills adapter":
    var locks = initLockManager()
    let running = locks.acquire(LockSelection(kind: lkNone), 1, 100,
      persistentAdapter = true)
    check locks.cancel(running.id, 10) == csCancelPersistentAdapter
    check locks.advance(5_010) == @[(running.id, csKillPersistentAdapter)]
