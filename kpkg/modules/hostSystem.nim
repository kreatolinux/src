# Resolves the "system release" for a root, on Kreato Linux and on foreign hosts.
#
# Kreato stores its identity in /etc/kreato-release. kpkgTarget(), getLibc() and
# getInit() all need those Core values in order to build a target string such as
# "aarch64-linux-gnu-jumpstart-openssl". On a foreign host (Ubuntu, Debian,
# Fedora, Arch, Alpine) that file does not exist, which used to make kpkg fatal
# before it could do anything at all. That is the main reason kpkg could not be
# used to bootstrap Kreato onto a foreign base.
#
# Resolution order for a given root:
#   1. an explicit release path handed in by the caller
#   2. <root>/etc/kreato-release           (a real Kreato system or rootfs)
#   3. $KPKG_HOST_RELEASE                  (explicit override, set by seed images)
#   4. /etc/kpkg/host-release.conf         (persisted override)
#   5. synthesized from /etc/os-release    (best effort, warns once)
#
# A synthesized release is never written to disk. It exists only so that target
# strings and libc/init lookups keep working during a bootstrap build. Callers
# that genuinely need a real Kreato release should check isKreato() themselves.

import os
import strutils
import parsecfg
import ../../common/logging

const kreatoReleaseName* = "etc/kreato-release"
const hostReleaseEnv* = "KPKG_HOST_RELEASE"
const hostReleasePath* = "/etc/kpkg/host-release.conf"

var warnedForeign = false

proc osReleaseField*(root: string, key: string): string =
  ## Reads KEY="VALUE" out of <root>/etc/os-release. Returns "" when absent.
  let file = root / "etc/os-release"
  if not fileExists(file):
    return ""

  for rawLine in lines(file):
    let line = rawLine.strip()
    if line.startsWith(key & "="):
      var value = line[(key.len + 1) ..< line.len].strip()
      if value.len >= 2 and value[0] == '"' and value[^1] == '"':
        value = value[1 ..< value.len - 1]
      return value

  return ""

proc isKreato*(root: string): bool =
  ## True when root carries a real Kreato release file.
  fileExists(root / kreatoReleaseName)

proc isForeign*(root: string): bool =
  ## True when root is not a Kreato system.
  not isKreato(root)

proc detectInit(root: string): string =
  ## Best-effort init detection for a foreign root.
  var probe = ""

  if root == "/" and fileExists("/proc/1/comm"):
    try:
      probe = readFile("/proc/1/comm").strip()
    except CatchableError:
      probe = ""

  if probe == "":
    let sbinInit = root / "sbin/init"
    if symlinkExists(sbinInit):
      probe = lastPathPart(expandSymlink(sbinInit))
    elif fileExists(sbinInit):
      probe = "init"

  let p = probe.toLowerAscii()

  # First pattern that appears in the probe wins; init implementations
  # usually announce themselves in the process name.
  const knownInits = [
    ("systemd", "systemd"),
    ("jumpstart", "jumpstart"),
    ("openrc", "openrc"),
    ("runit", "runit"),
    ("busybox", "busybox"),
  ]
  for (pattern, name) in knownInits:
    if pattern in p:
      return name

  if p in ["", "init"]:
    return "busybox"

  return probe

proc synthesizeRelease*(root: string): Config =
  ## Builds a Kreato-shaped release config from what a foreign host exposes.
  result = newConfig()

  let id = osReleaseField(root, "ID").toLowerAscii()
  let idLike = osReleaseField(root, "ID_LIKE").toLowerAscii()
  let combined = (id & " " & idLike).strip()

  var libc = "glibc"
  var coreutils = "gnu"
  if "alpine" in combined:
    libc = "musl"
    coreutils = "busybox"

  result.setSectionKey("Core", "libc", libc)
  result.setSectionKey("Core", "coreutils", coreutils)
  result.setSectionKey("Core", "tlsLibrary", "openssl")
  result.setSectionKey("Core", "compiler", "gcc")
  result.setSectionKey("Core", "init", detectInit(root))

  result.setSectionKey("General", "foreign", "true")
  result.setSectionKey("General", "hostId", id)

proc resolveReleasePath*(root: string, explicit = ""): string =
  ## Resolves which release file to read. "" means "none found".
  if not isEmptyOrWhitespace(explicit):
    return explicit

  let kreato = root / kreatoReleaseName
  if fileExists(kreato):
    return kreato

  let envRelease = getEnv(hostReleaseEnv)
  if not isEmptyOrWhitespace(envRelease) and fileExists(envRelease):
    return envRelease

  if fileExists(hostReleasePath):
    return hostReleasePath

  return ""

proc validRelease(conf: Config): bool =
  ## A release config is usable when the Core keys every consumer reads exist.
  for key in ["libc", "init", "tlsLibrary"]:
    if isEmptyOrWhitespace(conf.getSectionValue("Core", key)):
      return false
  return true

proc resolveRelease*(root: string, explicit = ""): Config =
  ## Returns the release config for root, synthesizing one when needed.
  ## Never fatals. Prefer isKreato() when the caller needs a real Kreato root.
  let path = resolveReleasePath(root, explicit)

  if not isEmptyOrWhitespace(path):
    try:
      let conf = loadConfig(path)
      if validRelease(conf):
        return conf
      warn "release file '" & path &
          "' is missing Core keys (libc/init/tlsLibrary), synthesizing a release instead"
    except CatchableError:
      warn "could not parse release file '" & path &
          "', falling back to a synthesized release"

  let syn = synthesizeRelease(root)
  if not warnedForeign:
    warnedForeign = true
    warn "no /etc/kreato-release under '" & root & "'. Using a synthesized " &
        "release (libc=" & syn.getSectionValue("Core", "libc") & ", init=" &
        syn.getSectionValue("Core", "init") & ", tls=" &
        syn.getSectionValue("Core", "tlsLibrary") & ", coreutils=" &
        syn.getSectionValue("Core", "coreutils") & "). Set $" &
        hostReleaseEnv & "=/path/to/release.conf to control this."

  return syn

proc isForeignRelease*(conf: Config): bool =
  ## True when this release config was synthesized rather than read from Kreato.
  conf.getSectionValue("General", "foreign", "false") == "true"
