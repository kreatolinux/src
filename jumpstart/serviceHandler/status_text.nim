## Native status text and its §12.11 mapping (Appendix A). Dependency free so
## jumpctl can share it.
import std/[json, strutils]

const
  ExitCodePrefix* = "stopped with an exit code "
  MissingStatusText* = "stopped"
    ## What `jumpctl status` has always printed when no status file exists.

type
  NativeStatusMapping* = object
    state*: string
    exitCode*: int
    hasExitCode*: bool

proc mapNativeStatus*(text: string; present: bool;
                      requestedStop: bool): NativeStatusMapping =
  ## Map a native status file to a §12.11 state, per Appendix A.
  if not present: return NativeStatusMapping(state: "inactive")
  case text
  of "running", "mounted": NativeStatusMapping(state: "active")
  of "stopped": NativeStatusMapping(state: "inactive")
  else:
    if text.startsWith(ExitCodePrefix):
      try:
        let code = parseInt(text[ExitCodePrefix.len .. ^1])
        return NativeStatusMapping(
          state: (if requestedStop: "inactive" else: "failed"),
          exitCode: code, hasExitCode: true)
      except ValueError: discard
    NativeStatusMapping(state: "unknown")

proc targetStatusText*(state: string): string =
  ## §22.5: targets and multi decfiles have no status file.
  case state
  of "active": "running"
  of "inactive": "stopped"
  of "activating": "starting"
  of "failed": "failed"
  else: state

proc nativeStatusText*(statusResult: JsonNode): string =
  ## The text `jumpctl status` prints for a native unit (§21.2): the raw status
  ## file text for services, mounts and timers (carried in `detail`), and the
  ## §22.5 words for targets (whose result carries `members`).
  if statusResult.isNil or statusResult.kind != JObject: return ""
  if statusResult.hasKey("members"):
    return targetStatusText(statusResult{"state"}.getStr)
  statusResult{"detail"}.getStr
