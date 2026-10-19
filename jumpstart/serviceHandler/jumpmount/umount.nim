## Native mount units: unmount.
import std/os
import ../../../common/logging
import ../../configParser
import ../mount_syscalls
import jumpstartcore/errors
import ../globalVariables
import ../start
import main

proc stopMount*(ctx: NativeContext; mountName: string; lazy = false) =
  ## Unmount. Unmounting an inactive mount unit is a success. `lazy` (or the
  ## decfile's `lazy_unmount`) detaches the filesystem (MNT_DETACH).
  if not ctx.mountActive(mountName):
    info "Mount " & mountName & " is not mounted, no need to try stopping it"
    return
  let mountConfig = ctx.findMountConfig(mountName)
  let flags: cint = if lazy or mountConfig.lazyUnmount: MNT_DETACH else: 0
  let ret = umountFs(mountConfig.toPath, flags)
  if ret != 0:
    nativeFail(ecBackend, "unmounting " & mountName & " failed: " & mountErrorStr(ret))
  try: removeDir(ctx.mountStateDir(mountName))
  except CatchableError as e:
    warn "Could not clear state of mount " & mountName & ": " & e.msg
  ok "Unmounted " & mountName
