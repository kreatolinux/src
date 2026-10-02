## Offline tests for krep upstream-check eligibility.
import std/[os, tempfiles, unittest]
import ../../krep/commands/checkcmd as checkcmd

proc writeRun3(repo, name, extra: string): string =
  result = repo / name
  createDir(result)
  writeFile(result / "run3", "name: " & name & "\nversion: 1.0\nrelease: 1\n" & extra)

suite "krep update eligibility":
  setup:
    let work = createTempDir("krep eligibility-", "")
    let repo = work / "repo"
    createDir(repo)
  teardown:
    removeDir(work)

  test "run3 no_chkupd true is ineligible":
    let pkg = writeRun3(repo, "disabled", "no_chkupd: true\n")
    check not checkcmd.isUpstreamCheckEligible(pkg)

  test "run3 defaults to eligible and accepts explicit false":
    check checkcmd.isUpstreamCheckEligible(writeRun3(repo, "default", ""))
    check checkcmd.isUpstreamCheckEligible(writeRun3(repo, "enabled", "no_chkupd: false\n"))

  test "legacy run keeps eligibility without parsing shell syntax":
    let pkg = repo / "legacy"
    createDir(pkg)
    writeFile(pkg / "run", "NAME=legacy\nVERSION=1.0\nno_chkupd=true\n")
    check checkcmd.isUpstreamCheckEligible(pkg)

  test "single check and update paths skip before backend setup":
    discard writeRun3(repo, "disabled", "no_chkupd: true\n")
    # githubReleases would fail because there is no chkupd.cfg. Returning proves
    # policy evaluation happened before backend setup, and no request was made.
    checkcmd.check("disabled", repo, "githubReleases", autoUpdate = false)
    checkcmd.check("disabled", repo, "githubReleases", autoUpdate = true)

  test "wildcard check and update paths skip every disabled match":
    discard writeRun3(repo, "disabled-one", "no_chkupd: true\n")
    discard writeRun3(repo, "disabled-two", "no_chkupd: true\n")
    checkcmd.check("disabled-*", repo, "githubReleases", autoUpdate = false)
    checkcmd.check("disabled-*", repo, "githubReleases", autoUpdate = true)

  test "wildcard failures do not stop later package checks":
    let broken = repo / "a-broken"
    createDir(broken)
    writeFile(broken / "run3", "name: a-broken\nversion: 1.0\nrelease: 1\n")
    writeFile(broken / "chkupd.cfg", "[autoUpdater]\nmechanism=githubReleases\n[githubReleases]\nrepo=invalid\n")
    discard writeRun3(repo, "z-disabled", "no_chkupd: true\n")
    # The malformed package is reported, then the later disabled package is
    # still evaluated without configuring or contacting the backend.
    checkcmd.check("*", repo, "githubReleases", autoUpdate = false)
