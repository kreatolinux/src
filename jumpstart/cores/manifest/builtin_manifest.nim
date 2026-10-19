## The compiled-in `serviceHandler` manifest (specification Appendix A).
##
## `serviceHandler` has no `init.kg`. Its manifest is data: the daemon builds
## its dispatch plan from `serviceHandlerOps` and `jumpctl cores show
## serviceHandler` prints it with `formatShow`. `core_version`, `version`,
## and `jumpstart` all equal the running Jumpstart version, which callers pass
## in (taken from `jumpstartVersion`, §23.2).
import std/strutils
import ./[manifest, modes, types]
import jumpstartcore/registry

const
  ServiceHandlerName* = "serviceHandler"
  ServiceHandlerDescription* = "Jumpstart native service handler"
  ServiceHandlerSubsystems* = ["unit", "service", "mount", "timer", "target"]
  ## Appendix A `supported_ops`, verbatim and in registry order.
  ServiceHandlerOperations*: array[33, tuple[name: string; backend: BackendKind]] = [
    ("unit.list", bkNative),
    ("unit.resolve", bkNative),
    ("unit.load", bkNative),
    ("unit.validate", bkNative),
    ("unit.translate", bkUnsupported),
    ("unit.activate", bkNative),
    ("unit.deactivate", bkNative),
    ("service.start", bkNative),
    ("service.stop", bkNative),
    ("service.restart", bkNative),
    ("service.reload", bkUnsupported),
    ("service.kill", bkNative),
    ("service.enable", bkNative),
    ("service.disable", bkNative),
    ("service.status", bkNative),
    ("mount.start", bkNative),
    ("mount.stop", bkNative),
    ("mount.enable", bkNative),
    ("mount.disable", bkNative),
    ("mount.status", bkNative),
    ("timer.start", bkNative),
    ("timer.stop", bkNative),
    ("timer.enable", bkNative),
    ("timer.disable", bkNative),
    ("timer.status", bkNative),
    ("target.start", bkNative),
    ("target.stop", bkNative),
    ("target.isolate", bkNative),
    ("target.enable", bkNative),
    ("target.disable", bkNative),
    ("target.status", bkNative),
    ("target.set-default", bkNative),
    ("target.get-default", bkNative)]

proc serviceHandlerManifest*(jumpstartVersion: string): CoreManifest =
  ## The Appendix A manifest for the running Jumpstart. `jumpstartVersion`
  ## is `jumpstartVersion` (`jumpstart vX.Y.Z`) or its bare `X.Y.Z` form.
  let version = runningVersionNumber(jumpstartVersion)
  result = CoreManifest(manifestVersion: CurrentManifestVersion,
    name: ServiceHandlerName, description: ServiceHandlerDescription,
    coreVersion: version, version: version, jumpstart: "=" & version,
    jumpstartRange: parseVersionRange("=" & version),
    account: "root", accountDefaulted: true,
    modes: {cmSystem, cmUser}, subsystems: @ServiceHandlerSubsystems,
    activation: asCore)
  for (name, backend) in ServiceHandlerOperations:
    result.operations.add OperationEntry(name: name, backend: backend)
  # The same completeness and activation rules as every extension (§11.3).
  validateCompleteness(result)

proc serviceHandlerOps*(jumpstartVersion: string; mode: CoreMode): seq[ResolvedOp] =
  ## The resolved Appendix A operation table, in registry order. Operations
  ## outside the claimed subsystems (`core.*`, `socket.*`, `swap.*`,
  ## `path.*`, `log.*`) are absent and therefore unsupported (§11.4).
  resolveOps(serviceHandlerManifest(jumpstartVersion), mode)

proc isServiceHandlerNative*(operation: string): bool =
  ## True when Appendix A binds `operation` to the `native` backend.
  for (name, backend) in ServiceHandlerOperations:
    if name == operation: return backend == bkNative
  false

proc appendixAText*(jumpstartVersion: string): string =
  ## The manifest rendered as the Kongue header shown in Appendix A.
  let m = serviceHandlerManifest(jumpstartVersion)
  var lines = @["manifest_version: " & $m.manifestVersion,
    "name: \"" & m.name & "\"",
    "description: \"" & m.description & "\"",
    "core_version: \"" & m.coreVersion & "\"",
    "version: \"" & m.version & "\"",
    "jumpstart: \"" & m.jumpstart & "\"",
    "modes:", "  - \"system\"", "  - \"user\"", "", "subsystems:"]
  for sub in m.subsystems: lines.add "  - \"" & sub & "\""
  lines.add "activation: \"core\""
  lines.add ""
  lines.add "supported_ops:"
  for op in m.operations:
    lines.add "  - name: \"" & op.name & "\""
    lines.add "    backend: \"" & (if op.backend == bkNative: "native" else: "unsupported") & "\""
  lines.join("\n") & "\n"
