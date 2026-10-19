# Jumpstart paths and version shared by the daemon, serviceHandler, and
# jumpctl.
#
# serviceHandler/main.nim and the daemon `import` this module, so its globals
# exist once per thread there. jumpctl still `include`s it; no module may
# re-export these symbols, or jumpctl would see them twice. The paths are
# derived on first use from cores/modes (§7.1, §7.2): the mode comes from the
# real UID and `~` from the password database, never from HOME or XDG
# variables. Being a threadvar, the cache is per thread: worker threads derive
# the same values as the daemon even without configureJumpstartPaths.
import std/os
import cores/manifest/modes

proc jumpstartRealUid(): cint {.importc: "getuid", header: "<unistd.h>",
                                sideEffect, raises: [], tags: [], forbids: [].}

const jumpstartVersion* {.used.} = "jumpstart v2.0.0"

type JumpstartLegacyPaths = object
  ready: bool
  socket, config, runtime: string

var jumpstartLegacyPaths {.threadvar.}: JumpstartLegacyPaths

proc serviceHandlerRuntimePath*(paths: CorePaths): string {.used.} =
  ## serviceHandler keeps its historical runtime layout in system mode and
  ## lives beneath the selected user runtime directory in user mode.
  if paths.mode == cmSystem: "/run/serviceHandler"
  else: paths.runtimeRoot / "serviceHandler"

proc configureJumpstartPaths*(socketPath, configurationPath,
                              runtimePath: string) {.used.} =
  ## Override the derived paths for the calling module and thread (the daemon
  ## installs its validated paths; tests inject temporary roots).
  jumpstartLegacyPaths = JumpstartLegacyPaths(ready: true, socket: socketPath,
    config: configurationPath, runtime: runtimePath)

proc legacyJumpstartPaths(): JumpstartLegacyPaths =
  ## Raises ModeError when the real UID has no usable password-database home.
  ## Worker threads (timers, services) derive their own copy on first use.
  if not jumpstartLegacyPaths.ready:
    let uid = int(jumpstartRealUid())
    # pathsForPasswd only takes optional closure hooks (nil here); it reads the
    # password database and stats /run/user/UID, touching no shared heap.
    {.cast(gcsafe).}:
      let paths = pathsForPasswd(clientMode(uid), uid)
    configureJumpstartPaths(paths.socketPath, paths.configRoot,
                            serviceHandlerRuntimePath(paths))
  jumpstartLegacyPaths

template sockPath*: string {.used.} = legacyJumpstartPaths().socket
template configPath*: string {.used.} = legacyJumpstartPaths().config
template serviceHandlerPath*: string {.used.} = legacyJumpstartPaths().runtime
