import std/[algorithm, sequtils, strutils]
import nimcrypto/sha2
import ./types

proc abiForLibc*(libc: string): string =
  case libc.toLowerAscii()
  of "glibc": "gnu"
  of "musl": "musl"
  else: raise newException(ValueError, "unsupported libc '" & libc & "'")

proc libcForAbi*(abi: string): string =
  case abi.toLowerAscii()
  of "gnu": "glibc"
  of "musl": "musl"
  else: raise newException(ValueError, "unsupported target ABI '" & abi & "'")

proc targetForProfile*(profile: RootfsProfile): string =
  profile.arch & "-" & profile.os & "-" & abiForLibc(profile.libc) & "-" &
      profile.init & "-" & profile.tlsLibrary

proc normalizeProfile*(profile: var RootfsProfile) =
  profile.arch = profile.arch.toLowerAscii()
  profile.os = profile.os.toLowerAscii()
  profile.libc = profile.libc.toLowerAscii()
  profile.compiler = profile.compiler.toLowerAscii()
  profile.coreutils = profile.coreutils.toLowerAscii()
  profile.init = profile.init.toLowerAscii()
  profile.tlsLibrary = profile.tlsLibrary.toLowerAscii()
  profile.packageRoots = profile.packageRoots.filterIt(it.len > 0).deduplicate()
  profile.extraPackages = profile.extraPackages.filterIt(it.len > 0).deduplicate()
  profile.target = targetForProfile(profile)

proc canonicalProfile*(profile: RootfsProfile): string =
  var packageRoots = profile.packageRoots
  var extraPackages = profile.extraPackages
  packageRoots.sort()
  extraPackages.sort()
  result = "schema_version=" & $profile.schemaVersion & "\n" &
    "arch=" & profile.arch & "\n" &
    "os=" & profile.os & "\n" &
    "libc=" & profile.libc & "\n" &
    "compiler=" & profile.compiler & "\n" &
    "coreutils=" & profile.coreutils & "\n" &
    "init=" & profile.init & "\n" &
    "tls_library=" & profile.tlsLibrary & "\n" &
    "target=" & profile.target & "\n" &
    "package_roots=" & packageRoots.join(",") & "\n" &
    "extra_packages=" & extraPackages.join(",") & "\n"

proc profileFingerprint*(profile: RootfsProfile): string =
  var hash: sha256
  hash.init()
  hash.update(canonicalProfile(profile))
  "sha256:" & ($hash.finish()).toLowerAscii()

proc finalizeProfile*(profile: var RootfsProfile) =
  normalizeProfile(profile)
  profile.fingerprint = profileFingerprint(profile)

proc validateProfile*(profile: RootfsProfile) =
  if profile.schemaVersion != 1:
    raise newException(ValueError, "unsupported rootfs profile schema " &
        $profile.schemaVersion)
  for (name, value) in [("arch", profile.arch), ("os", profile.os),
      ("libc", profile.libc), ("compiler", profile.compiler),
      ("coreutils", profile.coreutils), ("init", profile.init),
      ("tls_library", profile.tlsLibrary)]:
    if value.len == 0:
      raise newException(ValueError, "rootfs profile is missing '" & name & "'")
  discard abiForLibc(profile.libc)
  if profile.init == "systemd" and profile.coreutils != "gnu":
    raise newException(ValueError, "systemd profiles require GNU coreutils")
  if profile.init == "busybox" and profile.coreutils != "busybox":
    raise newException(ValueError, "BusyBox init requires BusyBox coreutils")


proc parseTarget*(target: string): tuple[arch, os, libc, init,
    tlsLibrary: string] =
  let parts = target.split('-')
  if parts.len != 5:
    raise newException(ValueError, "invalid rootfs target '" & target &
        "'; expected <arch>-<os>-<abi>-<init>-<tls>")
  result = (parts[0], parts[1], libcForAbi(parts[2]), parts[3], parts[4])

proc resolvedPackageRoots*(profile: RootfsProfile,
    exclusions: seq[string] = @[]): seq[string]

proc profileFromTarget*(target, compiler, coreutils: string,
    extraPackages: seq[string] = @[]): RootfsProfile =
  let parsed = parseTarget(target)
  result = RootfsProfile(schemaVersion: 1, arch: parsed.arch, os: parsed.os,
    libc: parsed.libc, compiler: compiler, coreutils: coreutils,
    init: parsed.init, tlsLibrary: parsed.tlsLibrary,
    extraPackages: extraPackages)
  validateProfile(result)
  result.packageRoots = resolvedPackageRoots(result)
  finalizeProfile(result)

proc resolvedPackageRoots*(profile: RootfsProfile,
    exclusions: seq[string] = @[]): seq[string] =
  ## Resolve logical profile roots. Repository group expansion deliberately
  ## remains in dephandler/runfiles; notably GNU membership is `gnu-core`.
  result.add("kreato-fs-essentials")
  result.add(profile.tlsLibrary)
  case profile.compiler
  of "gcc": result.add(["gcc", "gmake"])
  of "clang": result.add(["llvm", "gmake"])
  of "no": discard
  else: raise newException(ValueError, "unsupported compiler '" &
      profile.compiler & "'")
  result.add(profile.libc)
  case profile.coreutils
  of "gnu": result.add("gnu-core")
  of "busybox": result.add("busybox")
  else: raise newException(ValueError, "unsupported coreutils profile '" &
      profile.coreutils & "'")
  case profile.init
  of "systemd": result.add(["dbus", "systemd"])
  of "busybox": discard # supplied by the coreutils profile
  of "jumpstart", "openrc", "runit": result.add(profile.init)
  else: raise newException(ValueError, "unsupported init '" & profile.init & "'")
  result.add(["libxcrypt", "shadow", "kpkg", "p11-kit",
    "ca-certificates-utils", "ca-certificates", "tzdb", "python",
    "python-pip"])
  result.add(profile.extraPackages)
  result = result.filterIt(it.len > 0 and it notin exclusions).deduplicate()

proc sourceProfileRoots*(profile: RootfsProfile): seq[string] =
  ## Only identity-defining roots; used for seeded-root replacement planning.
  result.add(profile.tlsLibrary)
  case profile.coreutils
  of "gnu": result.add("gnu-core")
  of "busybox": result.add("busybox")
  else: discard
  case profile.init
  of "systemd": result.add(["dbus", "systemd"])
  of "busybox": discard
  else: result.add(profile.init)
