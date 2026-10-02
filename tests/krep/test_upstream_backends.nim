import std/[unittest, json]
import ../../krep/modules/upstreamVersions
import ../../krep/modules/backends/[githubReleases, repology, arch]

suite "upstream backend selection":
  test "natural versions and prereleases":
    check compareUpstreamVersions("1.2.10.4", "1.2.9.99") > 0
    check compareUpstreamVersions("999999999999999999999", "10") > 0
    check compareUpstreamVersions("2.0-rc1", "2.0") < 0
    check compareUpstreamVersions("2.0-beta2", "2.0-rc1") < 0
    check compareUpstreamVersions("1.0.0", "1") == 0

  test "GitHub prefix removal is anchored and single":
    check normalizeGithubTag(" v1.2.3 ", "v") == "1.2.3"
    check normalizeGithubTag("release-release-1", "release-") == "release-1"
    check normalizeGithubTag("x-v1", "v") == "x-v1"
    check releaseForPython("1-3.14.7", "3.15.0") == "1-3.15.0"
    check releaseForPython("2", "3.15.0") == "2-3.15.0"
    check releaseForPython("1-3.15.0a1", "3.15.0a1") == "1-3.15.0a1"
    check releaseForPython("1-3.14.0rc2", "3.15.0a1") == "1-3.15.0a1"

  test "Repology chooses greatest stable newest version":
    let entries = parseJson("""[
      {"status":"newest","version":"2.0-rc1"},
      {"status":"outdated","version":"99"},
      {"status":"newest","version":"1.10"},
      {"status":"newest","version":"1.9"}
    ]""")
    check selectRepologyVersion(entries) == "1.10"
    check selectRepologyVersion(parseJson("[]")) == ""

  test "Arch selector requires exact stable package and understands epoch":
    let response = parseJson("""{"results":[
      {"pkgname":"demo-doc","repo":"Core","arch":"x86_64","pkgver":"99","pkgrel":"1"},
      {"pkgname":"demo","repo":"Testing","arch":"x86_64","pkgver":"9","pkgrel":"1"},
      {"pkgname":"demo","repo":"Extra","arch":"x86_64","epoch":0,"pkgver":"2.0","pkgrel":"4"},
      {"pkgname":"demo","repo":"Core","arch":"any","epoch":1,"pkgver":"1.0","pkgrel":"2"}
    ]}""")
    let chosen = selectArchResult(response, "demo")
    check chosen.pkgver == "1.0"
    check chosen.epoch == "1"
    check chosen.pkgrel == "2"
