import std/[algorithm, os, strutils, unittest]
import ../../../kpkg/modules/rootfs/[config, kongue_document, plan, profile, provision, state, types]

proc sampleProfile(): RootfsProfile =
  result = RootfsProfile(schemaVersion: 1, arch: "x86_64", os: "linux",
    libc: "glibc", compiler: "gcc", coreutils: "gnu", init: "systemd",
    tlsLibrary: "openssl", packageRoots: @["gnu-core", "dbus", "systemd"],
    extraPackages: @["nim", "gmake"])
  finalizeProfile(result)

suite "rootfs Kongue profile and state":
  test "same semantic profile has stable identity":
    var left = sampleProfile()
    var right = left
    right.packageRoots.reverse()
    right.extraPackages.reverse()
    finalizeProfile(right)
    check left.target == "x86_64-linux-gnu-systemd-openssl"
    check left.fingerprint == right.fingerprint
    check canonicalProfile(left) == canonicalProfile(right)

  test "strict documents reject executable and mutable input":
    expect DeclarativeKongueError:
      discard parseDeclarativeKongue("build {\n  exec echo bad\n}\n")
    expect DeclarativeKongueError:
      discard parseDeclarativeKongue("arch +: x86_64\n")
    expect DeclarativeKongueError:
      discard parseDeclarativeKongue("arch: x86_64\narch: aarch64\n")
    expect DeclarativeKongueError:
      discard parseDeclarativeKongue("arch: ${HOST_ARCH}\n")

  test "state encoding is deterministic and round trips":
    let profile = sampleProfile()
    let original = RootfsState(schemaVersion: 1, status: rsReady,
      target: profile.target, profileFingerprint: profile.fingerprint,
      rootMode: rmSeeded, acquisitionMode: amSeedThenBinary,
      profile: profile, packageRoots: profile.packageRoots,
      extraPackages: profile.extraPackages)
    let encoded = encodeRootfsState(original)
    let decoded = decodeRootfsState(encoded)
    check encodeRootfsState(decoded) == encoded
    check decoded.status == rsReady
    check decoded.profileFingerprint == profile.fingerprint

  test "state detects profile mismatch":
    let profile = sampleProfile()
    let original = RootfsState(schemaVersion: 1, status: rsReady,
      target: profile.target, profileFingerprint: profile.fingerprint,
      rootMode: rmSeeded, acquisitionMode: amSeedThenBinary,
      profile: profile, packageRoots: profile.packageRoots,
      extraPackages: profile.extraPackages)
    expect ValueError:
      discard decodeRootfsState(encodeRootfsState(original).replace(
        "coreutils: \"gnu\"", "coreutils: \"busybox\""))

  test "loads a declarative rootfs config":
    let path = getTempDir() / "kpkg-rootfs-config-test.kg"
    defer:
      if fileExists(path): removeFile(path)
    writeFile(path, """schema_version: "1"
build_directory: "/out"
package_mode: "binary"
use_overlay: "true"
arch: "x86_64"
os: "linux"
libc: "glibc"
compiler: "gcc"
coreutils: "gnu"
init: "systemd"
tls_library: "openssl"
extra_packages:
  - "nim"
  - "gmake"
""")
    let loaded = loadRootfsConfig(path)
    check loaded.profile.target == "x86_64-linux-gnu-systemd-openssl"
    check loaded.profile.extraPackages == @["nim", "gmake"]


suite "rootfs deterministic provisioning plan":
  test "empty and seeded plans converge to the same desired roots":
    let desired = sampleProfile()
    var source = desired
    source.coreutils = "busybox"
    source.init = "jumpstart"
    source.packageRoots = @["busybox", "jumpstart"]
    finalizeProfile(source)
    let empty = makeRootfsPlan(desired)
    let seeded = makeRootfsPlan(desired, rmSeeded, source)
    check empty.install == seeded.install
    check "busybox" in seeded.remove
    check "jumpstart" in seeded.remove

  test "downloads complete before removals and installs":
    let plan = makeRootfsPlan(sampleProfile())
    var events: seq[string]
    provision(plan,
      proc(package, target: string) = events.add("acquire:" & package),
      proc(package: string) = events.add("remove:" & package),
      proc(package: string) = events.add("install:" & package))
    let firstInstall = events.find("install:" & plan.install[0])
    check firstInstall == plan.acquire.len
    for index in 0 ..< firstInstall:
      check events[index].startsWith("acquire:")

  test "bootstrap exclusions remove profile packages under construction":
    let plan = makeRootfsPlan(sampleProfile(), exclusions = @["systemd"])
    check "systemd" notin plan.acquire
    check "systemd" notin plan.install


suite "rootfs architecture normalization":
  test "architectures differ only in their architecture identity":
    var amd64 = sampleProfile()
    var arm64 = amd64
    arm64.arch = "aarch64"
    finalizeProfile(arm64)
    check amd64.packageRoots == arm64.packageRoots
    check amd64.extraPackages == arm64.extraPackages
    check amd64.target != arm64.target
    check amd64.fingerprint != arm64.fingerprint
