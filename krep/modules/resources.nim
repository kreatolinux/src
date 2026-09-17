## Locate image assets without depending on the process working directory.
import std/os

const sourceDataDir* = currentSourcePath().parentDir.parentDir / "data"

proc resourceDirAt(base, kind: string): string =
  if dirExists(base / kind):
    return absolutePath(base / kind)
  # Accept an explicit command-specific asset directory.
  if (kind == "rootfs" and dirExists(base / "arch")) or
      (kind == "iso" and fileExists(base / "grub.cfg")):
    return absolutePath(base)

proc resolveResourceDir*(kind: string, dataDir = "", appDir = getAppDir(),
                         sourceDir = sourceDataDir): string =
  ## Search explicit dataDir, KREP_DATA_DIR, installed ../share/krep,
  ## build-tree share/krep, then the source tree. Explicit overrides are
  ## authoritative: missing resources do not select a different installation.
  ## Shared data directories contain rootfs/ and iso/. Direct command-specific
  ## asset directories also work.
  if kind notin ["rootfs", "iso"]:
    raise newException(ValueError, "Unknown resource kind: " & kind)
  let overrideDir = if dataDir.len > 0: dataDir else: getEnv("KREP_DATA_DIR")
  if overrideDir.len > 0:
    result = resourceDirAt(overrideDir, kind)
    if result.len == 0:
      raise newException(ValueError, "Cannot find " & kind &
          " resources in " & overrideDir)
    return
  result = resourceDirAt(appDir.parentDir / "share/krep", kind)
  if result.len > 0: return
  result = resourceDirAt(appDir / "share/krep", kind)
  if result.len > 0: return
  # Also support a portable binary bundled beside its assets.
  result = resourceDirAt(appDir, kind)
  if result.len > 0: return
  if sourceDir.len > 0:
    result = resourceDirAt(sourceDir, kind)
  if result.len == 0:
    raise newException(ValueError, "Cannot find " & kind &
        " resources; pass --dataDir or set KREP_DATA_DIR")
