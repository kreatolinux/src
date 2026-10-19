## Native mount units: mount, and the shared lookup used by stop and status.
import std/[json, os, strutils]
import ../../../common/logging
import fusion/filepermissions
import ../../configParser
import ../mount_syscalls
import jumpstartcore/errors
import ../globalVariables
import ../start
import ../status_text
import ../status

proc findMountConfig*(ctx: NativeContext; mountName: string): MountConfig =
  ## `data` (data.kg with type mount) or `example::data`. Raises E_NOT_FOUND.
  let (definition, sub) = splitUnitName(mountName)
  var config: UnitConfig
  try:
    config = parseUnit(ctx.configRoot, definition)
  except CatchableError as e:
    nativeFail(ecNotFound, "mount " & mountName & " couldn't be loaded: " & e.msg)
  if config.unitType notin {utMount, utMulti}:
    nativeFail(ecNotFound, "mount " & mountName & " has an incorrect type: " &
      $config.unitType)
  for mnt in config.mounts:
    if mnt.name == sub: return mnt
  if "::" notin mountName and config.mounts.len == 1:
    return config.mounts[0]
  nativeFail(ecNotFound, "mount " & mountName & " not found in unit configuration")

proc mountActive*(ctx: NativeContext; mountName: string): bool =
  dirExists(ctx.mountStateDir(mountName))

proc startMount*(ctx: NativeContext; mountName: string) =
  ## Mount. Mounting an active mount unit is a success.
  if ctx.mountActive(mountName):
    info "Mount " & mountName & " is already mounted"
    return
  let mountConfig = ctx.findMountConfig(mountName)
  if mountConfig.fromPath == "" or mountConfig.toPath == "" or
      mountConfig.fstype == "":
    nativeFail(ecBackend, "mount " & mountName &
      " is missing required fields (from, to, fstype)")
  try:
    if not dirExists(mountConfig.toPath):
      createDir(mountConfig.toPath)
      chmod(mountConfig.toPath, mountConfig.chmod)
  except CatchableError as e:
    nativeFail(ecIo, "cannot create mount point " & mountConfig.toPath & ": " & e.msg)
  # extraArgs is passed directly as the filesystem-specific data string.
  let ret = mountFs(mountConfig.fromPath, mountConfig.toPath, mountConfig.fstype,
                    flags = 0, data = mountConfig.extraArgs)
  if ret != 0:
    nativeFail(ecBackend, "mounting " & mountName & " failed: " & mountErrorStr(ret))
  try:
    createDir(ctx.mountStateDir(mountName))
    writeFile(ctx.mountStateDir(mountName) / "status", "mounted")
  except CatchableError as e:
    warn "Could not record state of mount " & mountName & ": " & e.msg
  ok "Mounted " & mountName

proc mountStatus*(ctx: NativeContext; mountName: string): JsonNode =
  ## `mount.status` without `enablement`.
  let path = ctx.mountStateDir(mountName) / "status"
  var text = ""
  let present = readStatusFile(path, text)
  let mapping = mapNativeStatus(text, present, false)
  var source, target, fstype = ""
  try:
    let config = ctx.findMountConfig(mountName)
    source = config.fromPath; target = config.toPath; fstype = config.fstype
  except CatchableError: discard
  %* {"state": mapping.state, "detail": (if present: text else: MissingStatusText),
      "source": source, "target": target, "fstype": fstype}
