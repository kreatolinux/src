## The daemon's view of the native `serviceHandler` core (§13.6, §20.3,
## Appendix A). The daemon owns routing, locking and lifecycle; these
## callbacks perform the native work synchronously. `serviceHandler/
## native_bridge.nim` provides the production implementation.
import std/[json, options]
import ../lifecycle/routing, ../manifest/types
import jumpstartcore/cgroups
export routing.ResolveReply, types.UnitSnapshot

type
  ServiceHandlerCallbacks* = object
    load*: proc(cgroups: Option[CoreCgroups]) {.closure.}
      ## §20.3: run the service-handler initialization (first load) or reread
      ## the decfiles (later loads). Starts nothing.
    resolve*: proc(name: string): ResolveReply {.closure.}
      ## `unit.resolve`, including the internal legacy-suffix hint (§14.3).
    dispatch*: proc(operation, unit: string; args: JsonNode): JsonNode {.closure.}
      ## Any other native operation; raises CoreError with the §18 code.
    units*: proc(): seq[UnitSnapshot] {.closure.}
      ## Active native units, for the busy check (§20.4).

proc available*(callbacks: ServiceHandlerCallbacks): bool =
  not callbacks.load.isNil and not callbacks.resolve.isNil and
    not callbacks.dispatch.isNil and not callbacks.units.isNil
