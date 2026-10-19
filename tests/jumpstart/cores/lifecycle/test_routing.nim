import std/[sets, strutils, unittest]
import ../../../../jumpstart/cores/lifecycle/routing
import jumpstartcore/errors

proc core(name: string; state = crLoaded; enabled = true;
          reply = ResolveReply(); index = initNameIndex()): CoreRouteState =
  CoreRouteState(name: name, state: state, enabled: enabled,
    reply: reply, nameIndex: index)

proc expectCode(code: CoreErrorCode; body: proc() {.closure.}): ref CoreError =
  try:
    body()
    check false
  except CoreError as error:
    check error.code == code
    result = error

proc arg(mapping: OperationMapping; name: string): string =
  for item in mapping.arguments:
    if item.name == name: return item.value

suite "pure core routing model":
  test "qualified references select only the named loaded core":
    let states = @[
      core("serviceHandler", reply = answered(true, "ssh", "service")),
      core("systemd", reply = answered(true, "sshd.service", "service"))]
    let route = resolveOwner("systemd/sshd.service", states)
    check route.kind == rdOwner
    check route.core == "systemd"
    check route.name == "sshd.service"
    check route.subsystem == "service"

  test "qualified missing, unavailable and unowned cores do not fall back":
    let states = @[core("serviceHandler", reply = answered(true, "ssh", "service")),
      core("systemd", state = crUnloaded)]
    discard expectCode(ecNotFound, proc() = discard resolveOwner("missing/ssh", states))
    discard expectCode(ecCoreUnloaded,
      proc() = discard resolveOwner("systemd/ssh", states))
    let noOwner = @[core("systemd", reply = answered(false))]
    discard expectCode(ecNotFound,
      proc() = discard resolveOwner("systemd/ssh", noOwner))

  test "loading yields wait, timeout, and immediate self-load refusal":
    let states = @[core("systemd", state = crLoading)]
    check resolveOwner("systemd/ssh", states).kind == rdWait
    discard expectCode(ecTimeout,
      proc() = discard resolveOwner("systemd/ssh", states, loadingTimedOut = true))
    discard expectCode(ecCoreState,
      proc() = discard resolveOwner("systemd/ssh", states,
        callerLoadingCore = "systemd"))
    discard expectCode(ecNotFound,
      proc() = discard resolveOwner("ssh", states, callerLoadingCore = "systemd"))

  test "unqualified resolution selects exactly one canonical owner":
    let states = @[
      core("serviceHandler", reply = answered(false)),
      core("systemd", reply = answered(true, "sshd.service", "service"))]
    let route = resolveOwner("ssh", states)
    check route.core == "systemd"
    check route.name == "sshd.service"

  test "multiple claims are ambiguous and list qualified alternatives":
    let states = @[
      core("serviceHandler", reply = answered(true, "sshd", "service")),
      core("systemd", reply = answered(true, "sshd.service", "service"))]
    let error = expectCode(ecAmbiguous, proc() = discard resolveOwner("sshd", states))
    check "serviceHandler/sshd" in error.msg
    check "systemd/sshd.service" in error.msg

  test "an indexed failed core blocks fallback":
    let states = @[
      core("serviceHandler", reply = answered(true, "sshd", "service")),
      core("systemd", state = crFailed, index = nameIndex(["sshd.service"]))]
    # It blocks only the exact opaque requested name.
    check resolveOwner("sshd", states).core == "serviceHandler"
    let states2 = @[
      core("serviceHandler", reply = answered(true, "sshd", "service")),
      core("systemd", state = crFailed, index = nameIndex(["sshd.service"]))]
    let error = expectCode(ecCoreFailed,
      proc() = discard resolveOwner("sshd.service", states2))
    check error.core == "systemd"
    check "qualified" in error.msg

  test "unloaded, degraded and resolve failures preserve their own errors":
    for stateCode in [(crUnloaded, ecCoreUnloaded), (crDegraded, ecDegraded)]:
      let states = @[core("other", state = stateCode[0],
        index = nameIndex(["unit"]))]
      discard expectCode(stateCode[1], proc() = discard resolveOwner("unit", states))
    let broken = @[core("other", reply = failedReply(ecTimeout, "adapter timed out"),
      index = nameIndex(["unit"]))]
    let error = expectCode(ecTimeout, proc() = discard resolveOwner("unit", broken))
    check error.msg == "adapter timed out; use a qualified reference for other/unit"

  test "unknown index and native legacy match conservatively block fallback":
    let states = @[
      core("serviceHandler", reply = answered(true, "sshd", "service",
        legacySuffix = true)),
      core("systemd", state = crFailed)]
    discard expectCode(ecCoreFailed,
      proc() = discard resolveOwner("sshd.service", states))

    let knownEmpty = @[
      core("serviceHandler", reply = answered(true, "sshd", "service",
        legacySuffix = true)),
      core("systemd", state = crFailed, index = nameIndex([]))]
    let route = resolveOwner("sshd.service", knownEmpty)
    check route.core == "serviceHandler"
    check route.warnings.len == 1

  test "irrelevant unavailable cores become warnings and disabled indexes are ignored":
    let states = @[
      core("serviceHandler", reply = answered(true, "web", "service")),
      core("broken", state = crFailed, index = nameIndex(["other"])),
      core("disabled", state = crFailed, enabled = false, index = nameIndex(["web"]))]
    let route = resolveOwner("web", states)
    check route.core == "serviceHandler"
    check route.warnings.len == 1
    check route.warnings[0].core == "broken"

  test "name indexes replace lists and accumulate owned aliases":
    var index = nameIndex(["old"])
    index.replaceNames(["listed"])
    check "old" notin index.names
    check "listed" in index.names
    index.recordOwned("alias", "canonical")
    check index.known
    check "alias" in index.names
    check "canonical" in index.names
    expect CoreError: index.recordOwned("bad/name", "canonical")

  test "invalid references and invalid resolver output are typed errors":
    discard expectCode(ecName, proc() = discard resolveOwner("bad/name/again", @[]))
    let invalid = @[core("systemd", reply = answered(true, "bad name", "service"))]
    discard expectCode(ecProtocol, proc() = discard resolveOwner("unit", invalid))

  test "unit names that begin with a dash route like any other name (§14.1)":
    let states = @[
      core("serviceHandler", reply = answered(false)),
      core("systemd", reply = answered(true, "-.mount", "mount"))]
    let plain = resolveOwner("-.mount", states)
    check plain.kind == rdOwner
    check plain.core == "systemd"
    check plain.name == "-.mount"
    check plain.subsystem == "mount"
    let qualified = resolveOwner("systemd/-.mount", states)
    check qualified.core == "systemd"
    check qualified.name == "-.mount"
    var index = initNameIndex()
    index.recordOwned("-.slice", "-.slice")
    check "-.slice" in index.names
    let silent = @[core("systemd", state = crFailed, index = nameIndex(["-.mount"]))]
    discard expectCode(ecCoreFailed, proc() = discard resolveOwner("-.mount", silent))

suite "request-to-operation mapping":
  test "subsystem operations and fixed-subsystem operations map exactly":
    check mapOperation("socket", ucStart).operation == "socket.start"
    check mapOperation("timer", ucStatus).operation == "timer.status"
    check mapOperation("mount", ucStop).operation == "mount.stop"
    check mapOperation("mount", ucStop).arg("lazy") == "false"
    check mapOperation("service", ucRestart).operation == "service.restart"
    check mapOperation("socket", ucReload).operation == "service.reload"
    check mapOperation("target", ucIsolate).operation == "target.isolate"
    check mapOperation("target", ucSetDefault).operation == "target.set-default"
    check mapOperation("service", ucValidate).operation == "unit.validate"
    check mapOperation("service", ucTranslate).operation == "unit.translate"

  test "kill defaults signal and accepts an explicit signal":
    check mapOperation("service", ucKill).arg("signal") == "SIGTERM"
    check mapOperation("service", ucKill, signal = "SIGHUP").arg("signal") == "SIGHUP"

  test "enable and disable pass now and bare target unchanged":
    let enabled = mapOperation("service", ucEnable, now = true, target = "multi-user")
    check enabled.operation == "service.enable"
    check enabled.arg("now") == "true"
    check enabled.arg("target") == "multi-user"
    check mapOperation("timer", ucDisable).operation == "timer.disable"
    discard expectCode(ecName,
      proc() = discard mapOperation("service", ucEnable, target = "core/target"))

  test "log operations and global mappings are exact":
    check mapOperation("service", ucLogRead).operation == "log.read"
    check mapOperation("service", ucLogFollow).operation == "log.follow"
    check mapOperation("service", ucLogWrite).operation == "log.write"
    check mapGlobalOperation("get-default") == "target.get-default"
    check mapGlobalOperation("log-follow") == "log.follow"

  test "string actions and unknown actions":
    check mapOperation("service", "start").operation == "service.start"
    discard expectCode(ecUsage,
      proc() = discard mapOperation("service", "frobnicate"))
    discard expectCode(ecUsage,
      proc() = discard mapGlobalOperation("start"))
