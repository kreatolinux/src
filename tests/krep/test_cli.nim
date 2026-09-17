## Native, offline integration tests for the prebuilt krep executable.
## Build out/krep first, or set KREP_TEST_BINARY to an executable path.
## No command here builds images, cleans host archives, or contacts upstreams.
import std/[algorithm, json, os, osproc, streams, strutils, tables, tempfiles,
            unittest]

const sourceRoot = currentSourcePath().parentDir.parentDir.parentDir
let binary = absolutePath(getEnv("KREP_TEST_BINARY", sourceRoot / "out/krep"))
if not fileExists(binary):
  quit("krep CLI tests require a prebuilt executable: " & binary &
       "\nBuild out/krep first or set KREP_TEST_BINARY.", QuitFailure)
when defined(posix):
  if (getFilePermissions(binary) * {fpUserExec, fpGroupExec, fpOthersExec}) == {}:
    quit("KREP_TEST_BINARY is not executable: " & binary, QuitFailure)

type
  CommandResult = tuple[output: string, exitCode: int]
  FileSnapshot = object
    isFile, isDir, isLink: bool
    contents, target: string

proc snapshot(path: string): FileSnapshot =
  ## Read only. Never create or restore a host configuration or lock file.
  result.isFile = fileExists(path)
  result.isDir = dirExists(path)
  result.isLink = symlinkExists(path)
  if result.isLink:
    result.target = expandSymlink(path)
  if result.isFile:
    result.contents = readFile(path)

proc repositorySnapshot(path: string): Table[string, FileSnapshot] =
  result = initTable[string, FileSnapshot]()
  for kind, entry in walkDir(path):
    result[relativePath(entry, path)] = snapshot(entry)
    if kind == pcDir:
      for child, state in repositorySnapshot(entry):
        result[relativePath(entry, path) / child] = state

proc runCli(work: string, args: openArray[string]): CommandResult =
  ## Pass literal arguments directly: wildcard patterns must not reach a shell.
  let process = startProcess(binary, workingDir = work, args = args,
                            options = {poStdErrToStdOut})
  defer: close(process)
  result.output = process.outputStream.readAll()
  result.exitCode = process.waitForExit()

proc expectExit(work: string, args: openArray[string],
    code: int): CommandResult =
  result = runCli(work, args)
  checkpoint "krep " & args.join(" ") & "\n" & result.output
  check result.exitCode == code

proc expectFailure(work: string, args: openArray[string]): CommandResult =
  result = runCli(work, args)
  checkpoint "krep " & args.join(" ") & "\n" & result.output
  check result.exitCode != 0
  check result.output.strip.len > 0

const canonicalRunfile = "name: demo\nversion: 1.2.3\nrelease: 1\n" &
                        "description: \"CLI fixture\"\n"

proc packageFixture(repo: string, name = "demo", filename = "run3"): string =
  result = repo / name
  createDir(result)
  writeFile(result / filename, canonicalRunfile.replace("name: demo", "name: " & name))

suite "krep native CLI (offline)":
  setup:
    # Spaces in all fixture paths exercise argument handling without shell quoting.
    let work = createTempDir("krep cli tests-", "")
  teardown:
    removeDir(work)

  test "top-level help lists all commands and preserves host state":
    let configBefore = snapshot("/etc/kpkg/kpkg.conf")
    let lockBefore = snapshot("/tmp/kpkg.lock")
    let response = expectExit(work, ["--help"], 0)
    for command in ["check", "update", "clean", "lint", "fmt", "convert",
                    "generate", "rootfs", "iso"]:
      check command in response.output
    check snapshot("/etc/kpkg/kpkg.conf") == configBefore
    check snapshot("/tmp/kpkg.lock") == lockBefore

  test "every command and generation subcommand has side-effect-free help":
    let commands = @[@["check"], @["update"], @["clean"], @["lint"],
                     @["fmt"], @["convert"], @["generate"], @["rootfs"],
                     @["iso"], @["generate", "matrix"],
                     @["generate", "markdown"], @["generate", "manpage"]]
    for command in commands:
      let configBefore = snapshot("/etc/kpkg/kpkg.conf")
      let lockBefore = snapshot("/tmp/kpkg.lock")
      let response = expectExit(work, command & @["--help"], 0)
      check response.output.strip.len > 0
      check command[^1] in response.output.toLowerAscii
      check snapshot("/etc/kpkg/kpkg.conf") == configBefore
      check snapshot("/tmp/kpkg.lock") == lockBefore

  test "image help exposes resource overrides without loading or modifying them":
    let resources = work / "resource directory"
    createDir(resources)
    writeFile(resources / "sentinel", "must remain untouched\n")
    let before = repositorySnapshot(work)
    let configBefore = snapshot("/etc/kpkg/kpkg.conf")
    let lockBefore = snapshot("/tmp/kpkg.lock")
    let hadDataDir = existsEnv("KREP_DATA_DIR")
    let oldDataDir = getEnv("KREP_DATA_DIR")
    # This invalid resource path must never be resolved merely to display help.
    putEnv("KREP_DATA_DIR", work / "nonexistent resources")
    try:
      let rootfsHelp = expectExit(work,
          ["rootfs", "--help", "--dataDir=" & resources], 0)
      for flag in ["--buildType", "--arch", "--noSandbox", "--dataDir",
                   "--configPath", "--overlayPath"]:
        check flag in rootfsHelp.output
      let isoHelp = expectExit(work,
          ["iso", "--help", "--dataDir=" & resources], 0)
      for flag in ["--rootfs", "--output", "--init", "--dataDir", "--grubConfig",
                   "--kernelVersion", "--kernelImage", "--initramfs",
                   "--workDir",
                   "--imageSizeMiB", "--clearRootPassword", "--name",
                   "--overwrite"]:
        check flag in isoHelp.output
    finally:
      if hadDataDir: putEnv("KREP_DATA_DIR", oldDataDir)
      else: delEnv("KREP_DATA_DIR")
    check repositorySnapshot(work) == before
    check snapshot("/etc/kpkg/kpkg.conf") == configBefore
    check snapshot("/tmp/kpkg.lock") == lockBefore

  test "nested help targets one generator":
    let response = expectExit(work, ["generate", "help", "matrix"], 0)
    check "--repo" in response.output
    check "--pkgPath" notin response.output
    check "--file" notin response.output
    discard expectFailure(work, ["generate", "help", "not-a-generator"])

  test "version identifies krep and its commit":
    let response = expectExit(work, ["--version"], 0)
    check "krep " in response.output
    check "commit " in response.output

  test "unknown command and unknown options fail":
    discard expectFailure(work, ["not-a-krep-command"])
    discard expectFailure(work, ["--not-a-krep-option"])
    for command in ["check", "update", "lint", "fmt", "convert"]:
      discard expectFailure(work, [command, "--not-a-krep-option"])
    discard expectFailure(work, ["generate", "not-a-generator"])
    discard expectFailure(work, ["generate", "matrix", "--not-a-krep-option"])

  test "repository commands require package and repo options":
    for command in ["check", "update"]:
      discard expectFailure(work, [command])
      discard expectFailure(work, [command, "--package=never-matches-*"])
      discard expectFailure(work, [command, "--repo=" & work])

  test "generation and conversion required arguments are validated":
    discard expectFailure(work, ["generate", "matrix"])
    discard expectFailure(work, ["generate", "manpage"])
    discard expectFailure(work, ["generate", "manpage", "--file=" & work / "missing.md"])
    discard expectFailure(work, ["generate", "manpage", "--output=" & work / "out.md"])
    discard expectFailure(work, ["convert"])
    discard expectFailure(work, ["convert", "--fromVer=2"])
    discard expectFailure(work, ["convert", "--toVer=3"])
    discard expectFailure(work, ["convert", "--fromVer=not-an-int", "--toVer=3"])
    discard expectFailure(work, ["generate", "matrix", "--repo=" & work,
                                 "--limit=not-an-int"])

  test "check cannot opt into updates and update exposes its flags":
    let repo = work / "repo"
    discard packageFixture(repo)
    let before = repositorySnapshot(repo)
    let response = expectFailure(work, ["check", "--package=never-matches-*",
                                       "--repo=" & repo, "--autoUpdate"])
    check "autoUpdate".toLowerAscii in response.output.toLowerAscii
    check repositorySnapshot(repo) == before
    let checkHelp = expectExit(work, ["check", "--help"], 0)
    check "autoupdate" notin checkHelp.output.toLowerAscii
    let updateHelp = expectExit(work, ["update", "--help"], 0)
    for flag in ["--package", "--repo", "--backend", "--skipIfDownloadFails", "--verbose"]:
      check flag in updateHelp.output

  test "check with no wildcard matches is offline and read-only":
    let repo = work / "repo"
    let pkg = packageFixture(repo)
    writeFile(pkg / "chkupd.cfg", "[autoUpdater]\nmechanism=repology\n")
    writeFile(repo / "sentinel", "do not change\n")
    let before = repositorySnapshot(repo)
    let configBefore = snapshot("/etc/kpkg/kpkg.conf")
    let lockBefore = snapshot("/tmp/kpkg.lock")
    for backend in ["repology", "arch", "githubReleases"]:
      let response = expectExit(work, ["check", "--package=never-matches-*?",
                                      "--repo=" & repo, "--backend=" & backend], 0)
      check "No packages found matching pattern" in response.output
      check repositorySnapshot(repo) == before
    check snapshot("/etc/kpkg/kpkg.conf") == configBefore
    check snapshot("/tmp/kpkg.lock") == lockBefore

  test "fmt check succeeds for canonical input without writing":
    let pkg = packageFixture(work / "repo")
    let before = repositorySnapshot(pkg)
    discard expectExit(work, ["fmt", "--path=" & pkg / "run3", "--check"], 0)
    check repositorySnapshot(pkg) == before

  test "fmt check returns one for changes and fmt makes them canonical":
    let pkg = packageFixture(work / "repo")
    let path = pkg / "run3"
    let unformatted = "release: 1\nversion: \"1.2.3\"\nname: \"demo\"\n" &
                      "description: \"CLI fixture\"\n"
    writeFile(path, unformatted)
    let response = expectExit(work, ["fmt", "--path=" & path, "--check"], 1)
    check "would reformat" in response.output
    check readFile(path) == unformatted
    discard expectExit(work, ["fmt", "--path=" & path], 0)
    check readFile(path) == canonicalRunfile
    discard expectExit(work, ["fmt", "--path=" & path, "--check"], 0)

  test "fmt and lint return one for malformed input and missing paths":
    let path = work / "broken.run3"
    let malformed = "name: demo\nbuild {\n"
    writeFile(path, malformed)
    for command in ["fmt", "lint"]:
      let response = expectExit(work, [command, "--path=" & path], 1)
      check "error" in response.output.toLowerAscii
      check readFile(path) == malformed
      discard expectExit(work, [command, "--path=" & work / "missing"], 1)

  test "lint returns zero for valid input and one for missing required fields":
    let pkg = packageFixture(work / "repo")
    discard expectExit(work, ["lint", "--path=" & pkg / "run3"], 0)
    writeFile(pkg / "run3", "description: \"Missing required fields\"\n")
    let response = expectExit(work, ["lint", "--path=" & pkg], 1)
    for field in ["name", "version", "release"]:
      check "missing required variable: " & field in response.output

  test "convert rejects unsupported versions without changing input":
    let path = work / "run"
    let original = "NAME=demo\nVERSION=1.2.3\nRELEASE=1\n"
    writeFile(path, original)
    for versions in [(1, 3), (3, 2), (2, 2), (2, 4)]:
      let response = expectExit(work, ["convert", "--fromVer=" & $versions[0],
                                      "--toVer=" & $versions[1], "--path=" &
                                          path,
                                      "--inPlace"], 1)
      check "unsupported conversion" in response.output
      check readFile(path) == original
      check not fileExists(work / "run3")

  test "convert rejects conflicting write modes":
    let path = work / "run"
    writeFile(path, "NAME=demo\n")
    let response = expectExit(work, ["convert", "--fromVer=2", "--toVer=3",
                                    "--path=" & path, "--write", "--inPlace"], 1)
    check "cannot be used together" in response.output
    check readFile(path) == "NAME=demo\n"
    check not fileExists(work / "run3")

  test "matrix emits parseable JSON from run3 and fallback run fixtures":
    let repo = work / "repo"
    let demo = packageFixture(repo)
    # Both files in one directory must produce only one package entry.
    writeFile(demo / "run", canonicalRunfile)
    discard packageFixture(repo, "fallback", "run")
    let before = repositorySnapshot(repo)
    let output = work / "matrix output.json"
    discard expectExit(work, ["generate", "matrix", "--repo=" & repo,
                              "--output=" & output], 0)
    require fileExists(output)
    let matrix = parseFile(output)
    require matrix.kind == JObject
    require matrix.hasKey("include")
    require matrix["include"].kind == JArray
    var packages: seq[string]
    for entry in matrix["include"]:
      require entry.kind == JObject
      require entry.hasKey("packages")
      require entry["packages"].kind == JString
      packages.add(entry["packages"].getStr)
    packages.sort()
    check packages == @["demo", "fallback", "glibc", "musl"]
    check repositorySnapshot(repo) == before

  test "markdown generation writes package documentation":
    # A dependency-free package avoids host repository/database resolution.
    let pkg = packageFixture(work / "repo")
    let output = work / "package output.md"
    let before = repositorySnapshot(pkg)
    discard expectExit(work, ["generate", "markdown", "--pkgPath=" & pkg,
                              "--output=" & output], 0)
    require fileExists(output)
    let document = readFile(output)
    for text in ["title: demo", "CLI fixture", "1.2.3", "# Dependencies",
                 "No dependencies", "kpkg install demo", "kpkg build demo",
                 "# Dependency Graph", "```mermaid"]:
      check text in document
    check repositorySnapshot(pkg) == before

  test "manpage generation preserves body and adds website front matter":
    let input = work / "demo.1.md"
    let output = work / "manpage output.md"
    let source = "% DEMO(1)\n\n# NAME\ndemo - CLI fixture\n"
    writeFile(input, source)
    discard expectExit(work, ["generate", "manpage", "--file=" & input,
                              "--output=" & output], 0)
    require fileExists(output)
    check readFile(output) == "---\ntitle: \"DEMO(1)\"\ndraft: false\n---\n\n" &
                              "# NAME\ndemo - CLI fixture\n"
    check readFile(input) == source

  test "manpage generation rejects non-manpage input":
    let input = work / "not a manpage.md"
    let output = work / "must not exist.md"
    writeFile(input, "# Not a manpage\n")
    let response = expectExit(work, ["generate", "manpage", "--file=" & input,
                                    "--output=" & output], 1)
    check "is not a manpage" in response.output
    check not fileExists(output)
