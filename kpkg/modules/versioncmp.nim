## Version comparison utilities for kpkg
## 
## Handles semantic versioning comparison with epoch and release support.
## Version format: version-release[-epoch] (e.g., "7.0.0-1", "7.0.0-1-2")
## 
## Comparison priority (highest to lowest):
## 1. Epoch (higher = newer)
## 2. Version (semver comparison)
## 3. Release (higher = newer)

import strutils
import sequtils

type
  ParsedVersion* = object
    epoch*: int
    major*, minor*, patch*: int
    prerelease*: string # alpha, beta, rc, etc.
    prereleaseNum*: int # number after prerelease (e.g., 2 in alpha2)
    release*: int
    raw*: string        # Original string for fallback comparison

proc parseVersionComponent(s: string): tuple[num: int, pre: string, preNum: int] =
  ## Parse a version component like "0", "0-alpha2", "0alpha2"
  ## Returns (numeric part, prerelease string, prerelease number)
  var numStr = ""
  var preStr = ""
  var preNumStr = ""
  var inPre = false
  var inPreNum = false

  for c in s:
    if not inPre and c.isDigit:
      numStr.add(c)
    elif not inPre and c.isAlphaAscii:
      inPre = true
      preStr.add(c.toLowerAscii)
    elif inPre and c.isAlphaAscii:
      preStr.add(c.toLowerAscii)
    elif inPre and c.isDigit:
      inPreNum = true
      preNumStr.add(c)
    elif inPreNum and c.isDigit:
      preNumStr.add(c)

  let num = if numStr.len > 0: parseInt(numStr) else: 0
  let preNum = if preNumStr.len > 0: parseInt(preNumStr) else: 0

  return (num, preStr, preNum)

proc parseVersionPart(version: string): tuple[major, minor, patch: int,
                                               prerelease: string,
                                                   prereleaseNum: int] =
  ## Parse the version part (e.g., "7.0.0", "7.0.0-alpha2", "1.2.3rc1")
  var major, minor, patch = 0
  var prerelease = ""
  var prereleaseNum = 0

  # Split on dots
  let parts = version.split(".")

  if parts.len >= 1:
    let parsed = parseVersionComponent(parts[0])
    major = parsed.num
    if parsed.pre.len > 0:
      prerelease = parsed.pre
      prereleaseNum = parsed.preNum

  if parts.len >= 2:
    let parsed = parseVersionComponent(parts[1])
    minor = parsed.num
    if parsed.pre.len > 0 and prerelease.len == 0:
      prerelease = parsed.pre
      prereleaseNum = parsed.preNum

  if parts.len >= 3:
    let parsed = parseVersionComponent(parts[2])
    patch = parsed.num
    if parsed.pre.len > 0 and prerelease.len == 0:
      prerelease = parsed.pre
      prereleaseNum = parsed.preNum

  return (major, minor, patch, prerelease, prereleaseNum)

proc parseVersion*(versionString: string): ParsedVersion =
  ## Parse a full version string like "7.0.0-1" or "7.0.0-1-2" or "7.0.0-alpha2-1"
  ## Format: version-release[-epoch]

  result.raw = versionString

  if versionString.len == 0:
    return result

  let parts = versionString.split("-")

  if parts.len == 0:
    return result

  # First part is always the version (may contain prerelease like "7.0.0alpha2")
  let versionPart = parts[0]
  let vp = parseVersionPart(versionPart)
  result.major = vp.major
  result.minor = vp.minor
  result.patch = vp.patch
  result.prerelease = vp.prerelease
  result.prereleaseNum = vp.prereleaseNum

  # Handle remaining parts
  if parts.len >= 2:
    # Second part could be prerelease (alpha, beta, rc) or release number
    let secondPart = parts[1].toLowerAscii
    if secondPart.startsWith("alpha") or secondPart.startsWith("beta") or
       secondPart.startsWith("rc") or secondPart.startsWith("pre"):
      # It's a prerelease tag
      result.prerelease = secondPart.filterIt(it.isAlphaAscii).join("")
      let numPart = secondPart.filterIt(it.isDigit).join("")
      if numPart.len > 0:
        result.prereleaseNum = parseInt(numPart)

      # Release is next part if exists
      if parts.len >= 3:
        try:
          result.release = parseInt(parts[2])
        except ValueError:
          result.release = 0

      # Epoch is last part if exists
      if parts.len >= 4:
        try:
          result.epoch = parseInt(parts[3])
        except ValueError:
          result.epoch = 0
    else:
      # It's a release number
      try:
        result.release = parseInt(parts[1])
      except ValueError:
        result.release = 0

      # Epoch is next part if exists
      if parts.len >= 3:
        try:
          result.epoch = parseInt(parts[2])
        except ValueError:
          result.epoch = 0

proc comparePrereleases(a, b: string): int =
  ## Compare prerelease strings
  ## Empty string (release) > rc > beta > alpha > pre
  ## Returns: -1 (a < b), 0 (a == b), 1 (a > b)

  if a == b:
    return 0

  # Release versions (empty prerelease) are newer than prereleases
  if a.len == 0 and b.len > 0:
    return 1
  if a.len > 0 and b.len == 0:
    return -1

  # Define prerelease ordering (higher index = newer)
  let order = ["pre", "alpha", "beta", "rc"]

  var aIdx = -1
  var bIdx = -1

  for i, pre in order:
    if a.startsWith(pre):
      aIdx = i
    if b.startsWith(pre):
      bIdx = i

  if aIdx < 0: aIdx = order.len # Unknown prerelease treated as newer
  if bIdx < 0: bIdx = order.len

  if aIdx < bIdx:
    return -1
  elif aIdx > bIdx:
    return 1
  else:
    return 0

proc compareVersions*(a, b: string): int =
  ## Compare two version strings
  ## Returns: -1 (a < b, a is older), 0 (a == b), 1 (a > b, a is newer)

  if a == b:
    return 0

  let pA = parseVersion(a)
  let pB = parseVersion(b)

  # 1. Compare epoch (higher = newer)
  if pA.epoch != pB.epoch:
    return if pA.epoch > pB.epoch: 1 else: -1

  # 2. Compare major version
  if pA.major != pB.major:
    return if pA.major > pB.major: 1 else: -1

  # 3. Compare minor version
  if pA.minor != pB.minor:
    return if pA.minor > pB.minor: 1 else: -1

  # 4. Compare patch version
  if pA.patch != pB.patch:
    return if pA.patch > pB.patch: 1 else: -1

  # 5. Compare prerelease (release > rc > beta > alpha)
  let preCmp = comparePrereleases(pA.prerelease, pB.prerelease)
  if preCmp != 0:
    return preCmp

  # 6. Compare prerelease number (alpha2 > alpha1)
  if pA.prereleaseNum != pB.prereleaseNum:
    return if pA.prereleaseNum > pB.prereleaseNum: 1 else: -1

  # 7. Compare release number
  if pA.release != pB.release:
    return if pA.release > pB.release: 1 else: -1

  # Fallback to string comparison
  return cmp(a, b)

proc isNewer*(a, b: string): bool =
  ## Returns true if version 'a' is newer than version 'b'
  return compareVersions(a, b) > 0

proc isOlder*(a, b: string): bool =
  ## Returns true if version 'a' is older than version 'b'
  return compareVersions(a, b) < 0

proc isEqual*(a, b: string): bool =
  ## Returns true if versions are equal
  return compareVersions(a, b) == 0

proc newerVersion*(a, b: string): string =
  ## Returns the newer of two versions
  if isNewer(a, b):
    return a
  else:
    return b
