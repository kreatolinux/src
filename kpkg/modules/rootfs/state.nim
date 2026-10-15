import std/[os, parseutils]
import ./[types, profile, kongue_document]

const rootfsStateFile* = "rootfs-state.kg"
const
  stateScalars = ["schema_version", "status", "target",
    "profile_fingerprint", "root_mode", "acquisition_mode", "phase", "arch", "os",
    "libc", "compiler", "coreutils", "init", "tls_library",
    "failure_stage", "failure_package"]
  stateLists = ["package_roots", "extra_packages", "pending_packages",
    "completed_packages"]

proc quoteKongue(value: string): string =
  result = "\""
  for c in value:
    case c
    of '\\': result.add("\\\\")
    of '"': result.add("\\\"")
    of '\n': result.add("\\n")
    of '\r': result.add("\\r")
    of '\t': result.add("\\t")
    else: result.add(c)
  result.add('"')

proc addScalar(result: var string, key, value: string) =
  result.add(key & ": " & quoteKongue(value) & "\n")

proc addList(result: var string, key: string, values: seq[string]) =
  result.add(key & ":\n")
  for value in values:
    result.add("  - " & quoteKongue(value) & "\n")

proc encodeRootfsState*(state: RootfsState): string =
  addScalar(result, "schema_version", $state.schemaVersion)
  addScalar(result, "status", $state.status)
  addScalar(result, "target", state.target)
  addScalar(result, "profile_fingerprint", state.profileFingerprint)
  addScalar(result, "root_mode", $state.rootMode)
  addScalar(result, "acquisition_mode", $state.acquisitionMode)
  addScalar(result, "phase", $state.phase)
  result.add("\n")
  addScalar(result, "arch", state.profile.arch)
  addScalar(result, "os", state.profile.os)
  addScalar(result, "libc", state.profile.libc)
  addScalar(result, "compiler", state.profile.compiler)
  addScalar(result, "coreutils", state.profile.coreutils)
  addScalar(result, "init", state.profile.init)
  addScalar(result, "tls_library", state.profile.tlsLibrary)
  result.add("\n")
  addList(result, "package_roots", state.packageRoots)
  addList(result, "extra_packages", state.extraPackages)
  addList(result, "pending_packages", state.pendingPackages)
  addList(result, "completed_packages", state.completedPackages)
  if state.failureStage.len > 0:
    addScalar(result, "failure_stage", state.failureStage)
  if state.failurePackage.len > 0:
    addScalar(result, "failure_package", state.failurePackage)

proc parseStatus(value: string): RootfsStatus =
  for status in RootfsStatus:
    if $status == value: return status
  raise newException(ValueError, "invalid rootfs status '" & value & "'")

proc parseRootMode(value: string): RootMode =
  for mode in RootMode:
    if $mode == value: return mode
  raise newException(ValueError, "invalid root mode '" & value & "'")

proc parsePhase(value: string): ProvisionPhase =
  for phase in ProvisionPhase:
    if $phase == value: return phase
  raise newException(ValueError, "invalid provisioning phase '" & value & "'")

proc parseAcquisition(value: string): AcquisitionMode =
  for mode in AcquisitionMode:
    if $mode == value: return mode
  raise newException(ValueError, "invalid acquisition mode '" & value & "'")

proc decodeRootfsState*(content: string, path = "<memory>"): RootfsState =
  let doc = parseDeclarativeKongue(content, path)
  requireKnownFields(doc, path, stateScalars, stateLists)
  let schema = doc.scalar("schema_version")
  if parseInt(schema, result.schemaVersion) != schema.len:
    raise newException(ValueError, path & ": invalid schema_version")
  result.status = parseStatus(doc.scalar("status"))
  result.target = doc.scalar("target")
  result.profileFingerprint = doc.scalar("profile_fingerprint")
  result.rootMode = parseRootMode(doc.scalar("root_mode"))
  result.acquisitionMode = parseAcquisition(doc.scalar("acquisition_mode"))
  result.phase = parsePhase(doc.scalar("phase"))
  result.profile = RootfsProfile(schemaVersion: result.schemaVersion,
    arch: doc.scalar("arch"), os: doc.scalar("os"), libc: doc.scalar("libc"),
    compiler: doc.scalar("compiler"), coreutils: doc.scalar("coreutils"),
    init: doc.scalar("init"), tlsLibrary: doc.scalar("tls_library"),
    packageRoots: doc.list("package_roots"),
    extraPackages: doc.list("extra_packages"), target: result.target,
    fingerprint: result.profileFingerprint)
  result.packageRoots = doc.list("package_roots")
  result.extraPackages = doc.list("extra_packages")
  result.pendingPackages = doc.list("pending_packages")
  result.completedPackages = doc.list("completed_packages")
  result.failureStage = doc.scalar("failure_stage")
  result.failurePackage = doc.scalar("failure_package")
  validateProfile(result.profile)
  var normalized = result.profile
  finalizeProfile(normalized)
  if normalized.target != result.target:
    raise newException(ValueError, path & ": state target does not match profile")
  if normalized.fingerprint != result.profileFingerprint:
    raise newException(ValueError, path & ": state profile fingerprint is invalid")

proc loadRootfsState*(path: string): RootfsState =
  decodeRootfsState(readFile(path), path)

proc writeRootfsState*(path: string, state: RootfsState) =
  ## Same-directory temporary publication keeps readers from seeing partial state.
  let parent = parentDir(path)
  if parent.len > 0: createDir(parent)
  let temporary = path & ".partial"
  try:
    writeFile(temporary, encodeRootfsState(state))
    moveFile(temporary, path)
  except CatchableError:
    if fileExists(temporary): removeFile(temporary)
    raise
