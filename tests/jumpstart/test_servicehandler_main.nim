## serviceHandler PID 1 configuration and daemon integration helpers.
import std/[json, options, os, times, unittest]
import ../../jumpstart/serviceHandler/main
import ../../jumpstart/cores/native/native_api, ../../jumpstart/cores/lifecycle/routing
import jumpstartcore/[cgroups, reaper]
import ../../common/logging

proc tempDir(label: string): string =
  result = getTempDir() / ("jumpstart-sh-main-" & label & "-" &
    $getCurrentProcessId() & "-" & $int(epochTime() * 1000))
  createDir(result)

suite "serviceHandler PID 1 configuration":
  test "mount_fstab defaults to true and accepts false":
    let dir = tempDir("fstab"); defer: removeDir(dir)
    check readMountFstab(dir / "absent.conf")
    writeFile(dir / "main.conf", "[System]\nhostname=box\n")
    check readMountFstab(dir / "main.conf")
    writeFile(dir / "main.conf", "[System]\nmount_fstab=false\n")
    check not readMountFstab(dir / "main.conf")
    writeFile(dir / "main.conf", "[System]\nmount_fstab=true\n")
    check readMountFstab(dir / "main.conf")
    writeFile(dir / "main.conf", "[System]\nmount_fstab=maybe\n")
    check readMountFstab(dir / "main.conf")

  test "logging uses the path the daemon passes":
    let dir = tempDir("log"); defer: removeDir(dir)
    initServiceHandlerLogging(dir / "state/jumpstart.log", dir / "main.conf")
    check getDefaultLogger().logFilePath == dir / "state/jumpstart.log"

suite "serviceHandler daemon callbacks":
  test "callbacks resolve, dispatch and report units; the bridge is created at load":
    let dir = tempDir("callbacks"); defer: removeDir(dir)
    createDir(dir / "etc")
    writeFile(dir / "etc/web.kg", "description: \"w\"\ntype: \"simple\"\nservice {\n  exec \"sleep 30\"\n}\n")
    let ctx = newNativeContext(dir / "etc", dir / "run", newReaper(), stopTimeoutMs = 3000)
    var created: NativeBridge = nil
    let cb = serviceHandlerCallbacks(ctx, "jumpstart v2.0.0",
      proc(bridge: NativeBridge) = created = bridge)
    check cb.available
    # Before the first load nothing is owned and dispatch is refused.
    check not cb.resolve("web").owned
    cb.load(none(CoreCgroups))
    check not created.isNil
    let reply = cb.resolve("web.service")
    check reply.owned and reply.legacySuffix and reply.subsystem == "service"
    check cb.dispatch("service.start", "web", newJObject()) == %*{"state": "active"}
    check cb.units().len == 1
    check created.activeUnits() == @["web"]
    discard cb.dispatch("service.stop", "web", newJObject())
    check created.activeUnits().len == 0
    # A later load rereads decfiles on the same bridge.
    let first = created
    cb.load(none(CoreCgroups))
    check created == first

  test "configureServiceHandler builds a bridge without a global":
    let dir = tempDir("configure"); defer: removeDir(dir)
    createDir(dir / "etc")
    let bridge = configureServiceHandler(newNativeContext(dir / "etc", dir / "run",
      newReaper(), stopTimeoutMs = 3000))
    check not bridge.isNil
    check bridge.activeUnits().len == 0
