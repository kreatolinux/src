## Sandbox completion state. A release file or legacy envDateBuilt alone is
## not proof of success: older versions wrote them before postinstall hooks.
import std/[os, times]

const envSetupStateFile* = "envSetupState"

proc invalidateEnvSetup*(envRoot: string) =
  removeFile(envRoot / envSetupStateFile)
  removeFile(envRoot / "envDateBuilt")

proc markEnvDeferred*(envRoot: string) =
  invalidateEnvSetup(envRoot)
  writeFile(envRoot / envSetupStateFile, "deferred-v1")

proc canReuseEnv*(envRoot: string, deferPostInstall = false,
                  ignorePostInstall = false): bool =
  if not fileExists(envRoot / "etc/kreato-release") or
      not fileExists(envRoot / envSetupStateFile):
    return false
  try:
    case readFile(envRoot / envSetupStateFile)
    of "ready-v1":
      return fileExists(envRoot / "envDateBuilt")
    of "deferred-v1":
      return deferPostInstall
    of "legacy-skipped-v1":
      return ignorePostInstall or deferPostInstall
    else:
      return false
  except IOError:
    return false

proc finishEnvSetup*(envRoot: string, updateTrust, postInstall: proc(),
                     deferPostInstall = false, ignorePostInstall = false) =
  ## Publish completion only after every required setup action succeeds.
  ## Deferred state is usable only for an explicitly deferred build. The next
  ## normal build must recreate the env, rather than silently skip its hooks.
  ## ignorePostInstall retains isolation's legacy meaning (skip package hooks,
  ## but still run update-ca-trust); it is not the install command's option.
  invalidateEnvSetup(envRoot)
  if deferPostInstall:
    markEnvDeferred(envRoot)
    return
  updateTrust()
  if ignorePostInstall:
    writeFile(envRoot / envSetupStateFile, "legacy-skipped-v1")
    return
  postInstall()
  writeFile(envRoot / "envDateBuilt", now().format("yyyy-MM-dd"))
  writeFile(envRoot / envSetupStateFile, "ready-v1")
