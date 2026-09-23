## Tests for the host release resolver (hostSystem).
##
## These cover the bootstrap path: running kpkg on a host that has no
## /etc/kreato-release.

import unittest
import os
import strutils
import times
import parsecfg

import ../../../kpkg/modules/hostSystem
import ../../../kpkg/modules/commonTasks

var tmpRoot: string

var tmpCounter = 0

proc mkSuiteTmp(name: string): string =
  ## A fresh tmp dir per suite, so module level caching cannot leak between them.
  inc tmpCounter
  result = "/tmp/kpkg-hostsystem-" & name & "-" & $getTime().toUnix() & "-" &
      $getCurrentProcessId() & "-" & $tmpCounter
  createDir(result)

proc mkRoot(parent, name: string): string =
  result = parent / name
  createDir(result / "etc")

proc writeOsRelease(root, body: string) =
  writeFile(root / "etc" / "os-release", body)

suite "os-release parsing":
  var root: string

  setup:
    root = mkSuiteTmp("osrel")

  teardown:
    removeDir(root)

  test "reads a quoted field":
    let r = mkRoot(root, "quoted")
    writeOsRelease(r, "NAME=\"Ubuntu\"\nID=ubuntu\nID_LIKE=\"debian\"\nVERSION_ID=\"24.04\"\n")
    check osReleaseField(r, "ID") == "ubuntu"
    check osReleaseField(r, "ID_LIKE") == "debian"
    check osReleaseField(r, "VERSION_ID") == "24.04"

  test "reads an unquoted field":
    let r = mkRoot(root, "unquoted")
    writeOsRelease(r, "ID=alpine\n")
    check osReleaseField(r, "ID") == "alpine"

  test "missing key returns empty string":
    let r = mkRoot(root, "missing")
    writeOsRelease(r, "ID=ubuntu\n")
    check osReleaseField(r, "PRETTY_NAME") == ""

  test "missing os-release file returns empty string":
    let r = mkRoot(root, "noosrelease")
    check osReleaseField(r, "ID") == ""

suite "kreato vs foreign detection":
  var root: string

  setup:
    root = mkSuiteTmp("detect")

  teardown:
    removeDir(root)

  test "a root with kreato-release is Kreato":
    let r = mkRoot(root, "kreato")
    var conf = newConfig()
    conf.setSectionKey("Core", "libc", "glibc")
    conf.setSectionKey("Core", "init", "jumpstart")
    conf.setSectionKey("Core", "tlsLibrary", "openssl")
    conf.writeConfig(r / kreatoReleaseName)
    check isKreato(r)
    check not isForeign(r)

  test "a root without it is foreign":
    let r = mkRoot(root, "foreign")
    check not isKreato(r)
    check isForeign(r)

suite "synthesized releases":
  var root: string

  setup:
    root = mkSuiteTmp("syn")

  teardown:
    removeDir(root)

  test "ubuntu synthesizes glibc and gnu coreutils":
    let r = mkRoot(root, "syn-ubuntu")
    writeOsRelease(r, "ID=ubuntu\nID_LIKE=debian\n")
    let conf = synthesizeRelease(r)
    check conf.getSectionValue("Core", "libc") == "glibc"
    check conf.getSectionValue("Core", "coreutils") == "gnu"
    check conf.getSectionValue("Core", "tlsLibrary") == "openssl"
    check conf.isForeignRelease

  test "alpine synthesizes musl and busybox coreutils":
    let r = mkRoot(root, "syn-alpine")
    writeOsRelease(r, "ID=alpine\n")
    let conf = synthesizeRelease(r)
    check conf.getSectionValue("Core", "libc") == "musl"
    check conf.getSectionValue("Core", "coreutils") == "busybox"

  test "a real release file is not flagged foreign":
    let r = mkRoot(root, "syn-roundtrip")
    var conf = newConfig()
    conf.setSectionKey("Core", "libc", "glibc")
    conf.writeConfig(r / kreatoReleaseName)
    check not (loadConfig(r / kreatoReleaseName).isForeignRelease)

suite "resolution order":
  var root: string

  setup:
    root = mkSuiteTmp("order")
    delEnv("KPKG_HOST_RELEASE")

  teardown:
    removeDir(root)
    delEnv("KPKG_HOST_RELEASE")

  test "explicit path wins over everything":
    let r = mkRoot(root, "order-explicit")
    writeOsRelease(r, "ID=alpine\n")
    var explicitConf = newConfig()
    explicitConf.setSectionKey("Core", "libc", "glibc")
    explicitConf.setSectionKey("Core", "init", "jumpstart")
    explicitConf.setSectionKey("Core", "tlsLibrary", "openssl")
    let explicit = root / "explicit-release.conf"
    explicitConf.writeConfig(explicit)
    check resolveRelease(r, explicit).getSectionValue("Core", "init") == "jumpstart"

  test "kreato-release wins over KPKG_HOST_RELEASE":
    let r = mkRoot(root, "order-kreato")
    var kreato = newConfig()
    kreato.setSectionKey("Core", "libc", "glibc")
    kreato.setSectionKey("Core", "init", "jumpstart")
    kreato.setSectionKey("Core", "tlsLibrary", "openssl")
    kreato.writeConfig(r / kreatoReleaseName)
    var override = newConfig()
    override.setSectionKey("Core", "init", "systemd")
    let overridePath = root / "override.conf"
    override.writeConfig(overridePath)
    putEnv("KPKG_HOST_RELEASE", overridePath)
    check resolveRelease(r).getSectionValue("Core", "init") == "jumpstart"

  test "KPKG_HOST_RELEASE is used when there is no kreato-release":
    let r = mkRoot(root, "order-env")
    writeOsRelease(r, "ID=alpine\n")
    var override = newConfig()
    override.setSectionKey("Core", "libc", "glibc")
    override.setSectionKey("Core", "init", "jumpstart")
    override.setSectionKey("Core", "tlsLibrary", "openssl")
    let overridePath = root / "override.conf"
    override.writeConfig(overridePath)
    putEnv("KPKG_HOST_RELEASE", overridePath)
    let conf = resolveRelease(r)
    check conf.getSectionValue("Core", "init") == "jumpstart"
    check conf.getSectionValue("Core", "libc") == "glibc"
    check not conf.isForeignRelease

  test "falls back to synthesis when nothing exists":
    let r = mkRoot(root, "order-synth")
    writeOsRelease(r, "ID=alpine\n")
    let conf = resolveRelease(r)
    check conf.getSectionValue("Core", "libc") == "musl"
    check conf.isForeignRelease

  test "a broken release file falls back instead of raising":
    let r = mkRoot(root, "order-broken")
    writeFile(r / kreatoReleaseName, "this is not an ini file {{{\n")
    writeOsRelease(r, "ID=alpine\n")
    let conf = resolveRelease(r)
    check conf.getSectionValue("Core", "libc") == "musl"

suite "target strings on a foreign root":
  var root: string

  setup:
    root = mkSuiteTmp("target")
    delEnv("KPKG_HOST_RELEASE")

  teardown:
    removeDir(root)
    delEnv("KPKG_HOST_RELEASE")

  test "kpkgTarget resolves without a creato release file":
    let r = mkRoot(root, "target-foreign")
    writeOsRelease(r, "ID=ubuntu\nID_LIKE=debian\n")
    # Must not fatal. Format is <arch>-linux-<libc>-<init>-<tlsLibrary>.
    let target = kpkgTarget(r)
    let parts = target.split("-")
    check parts.len == 5
    check parts[1] == "linux"
    check parts[2] == "gnu"
    check parts[4] == "openssl"

  test "systemTarget maps the synthesized libc to a gnu triplet":
    let r = mkRoot(root, "target-system")
    writeOsRelease(r, "ID=ubuntu\n")
    check systemTarget(r).endsWith("-linux-gnu")

  test "customTarget overrides the resolved triplet prefix":
    let r = mkRoot(root, "target-custom")
    writeOsRelease(r, "ID=ubuntu\n")
    let target = kpkgTarget(r, customTarget = "aarch64-linux-gnu")
    check target.startsWith("aarch64-linux-gnu-")
