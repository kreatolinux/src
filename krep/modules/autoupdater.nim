import std/[os, strutils, tempfiles]
import regex
import ../../kpkg/modules/checksums
import ../../kpkg/modules/run3/run3
import ../../kpkg/modules/downloader

proc escapeRegex(s: string): string =
  ## Escape special regex characters in a string.
  result = ""
  for c in s:
    case c
    of '.', '^', '$', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '\\':
      result.add('\\')
      result.add(c)
    else:
      result.add(c)

proc replaceChecksumAtIndex(content, key: string, index: int,
                                oldValue, newValue: string): string =
  ## Replace one checksum list entry by position. Duplicate checksum values are
  ## valid, so global value replacement is not safe.
  var lines = content.splitLines()
  var inField = false
  var item = 0
  var replaced = false
  for lineIndex in 0 ..< lines.len:
    let stripped = lines[lineIndex].strip
    if not inField:
      if stripped == key & ":": inField = true
      continue
    if stripped.len > 0 and not lines[lineIndex][0].isSpaceAscii:
      break
    if stripped.startsWith("-"):
      if item == index:
        let pattern = "^(\\s*-\\s*\"?)" & escapeRegex(oldValue) &
          "(\"?\\s*)$"
        let expression = re2(pattern)
        if not lines[lineIndex].match(expression):
          raise newException(ValueError, "checksum " & $index &
            " does not match parsed metadata")
        lines[lineIndex] = lines[lineIndex].replace(expression,
          "${1}" & newValue & "${2}")
        replaced = true
        break
      inc item
  if not replaced:
    raise newException(ValueError, "checksum " & $index & " was not found")
  # splitLines retains the terminal empty element, so join preserves the exact
  # final-newline shape. Appending another newline here created a blank EOF line.
  result = lines.join("\n")

proc replaceMetadata(content, key, oldValue, newValue: string): string =
  ## Replace one complete run3 scalar, retaining its original quoting.
  let pattern = "^(" & escapeRegex(key) & ":\\s*\"?)" &
    escapeRegex(oldValue) & "(\"?\\s*)$"
  let expression = re2(pattern, {regexMultiline})
  var matches = 0
  for ignored in content.findAll(expression):
    discard ignored
    inc matches
  if matches != 1:
    raise newException(ValueError, key & " metadata does not occur exactly once")
  result = content.replace(expression, "${1}" & newValue & "${2}")

type SourceFetcher* = proc(source, destination: string) {.closure.}

proc autoUpdaterWithFetcher*(pkg: Run3File, packageDir: string,
                newVersion: string, skipIfDownloadFails: bool,
                release: string, fetcher: SourceFetcher) =
  ## Update a run3 recipe as one transaction. All downloads, checksums, and
  ## validation finish before the recipe is atomically replaced.
  echo "Autoupdating.."

  let packageDir = absolutePath(packageDir)
  let runPath = packageDir / "run3"
  if not fileExists(runPath):
    raise newException(IOError, "run3 file not found at: " & runPath)

  # Parse the file that will actually be replaced. This avoids using stale
  # metadata supplied by a caller while still retaining the public signature.
  discard pkg
  let recipe = parseRun3(packageDir)
  let sources = recipe.getSourcesWithVersion(newVersion)
  let version = recipe.getVersion()
  let pkgRelease = recipe.getRelease()
  let pkgName = recipe.getName()

  var oldSums: seq[string]
  var sumType = ""
  let checksumFamilies = int(recipe.getB2sum().len > 0) +
    int(recipe.getSha512sum().len > 0) + int(recipe.getSha256sum().len > 0)
  if checksumFamilies != 1:
    raise newException(ValueError, "recipe must define exactly one checksum family for '" & pkgName & "'")
  if recipe.getB2sum().len > 0:
    oldSums = recipe.getB2sum()
    sumType = "b2"
  elif recipe.getSha512sum().len > 0:
    oldSums = recipe.getSha512sum()
    sumType = "sha512"
  elif recipe.getSha256sum().len > 0:
    oldSums = recipe.getSha256sum()
    sumType = "sha256"

  if sources.len != oldSums.len:
    raise newException(ValueError, "source/checksum count mismatch for '" &
      pkgName & "': " & $sources.len & " sources, " & $oldSums.len &
      " checksums")

  let workDir = createTempDir("krep-autoupdate-", "")
  defer:
    if dirExists(workDir):
      removeDir(workDir)

  var newSums = oldSums
  for index, source in sources:
    # Local entries and SKIP are intentionally not fetched or rewritten.
    if not source.contains("://") or oldSums[index] == "SKIP":
      continue

    let downloadPath = workDir / ($index & "-" & extractFilename(source).strip())
    try:
      fetcher(source, downloadPath)
      newSums[index] = getSum(downloadPath, sumType)
    except CatchableError as failure:
      if skipIfDownloadFails:
        echo "WARN: '" & pkgName & "' failed because of download. Skipping."
        return
      raise newException(IOError, "'" & pkgName &
        "' failed because of download: " & failure.msg)

  # Build and validate the complete new recipe in memory.
  var content = readFile(runPath)
  content = replaceMetadata(content, "version", version, newVersion)
  if not isEmptyOrWhitespace(release):
    content = replaceMetadata(content, "release", pkgRelease, release)

  for index in 0 ..< oldSums.len:
    if newSums[index] != oldSums[index]:
      content = replaceChecksumAtIndex(content, sumType & "sum", index,
        oldSums[index], newSums[index])

  # The temporary file is in the package directory, so rename is atomic and
  # can never cross filesystems.
  let (temporary, temporaryPath) = createTempFile(".run3-autoupdate-", ".tmp",
    packageDir)
  temporary.close()
  var installed = false
  defer:
    if not installed and fileExists(temporaryPath):
      removeFile(temporaryPath)
  writeFile(temporaryPath, content)
  let validationDir = createTempDir("krep-validate-", "")
  defer:
    if dirExists(validationDir): removeDir(validationDir)
  writeFile(validationDir / "run3", content)
  discard parseRun3(validationDir)
  setFilePermissions(temporaryPath, getFilePermissions(runPath))
  moveFile(temporaryPath, runPath)
  installed = true

  echo "Autoupdate complete. As always, you should check if the package does build or not."


proc autoUpdater*(pkg: Run3File, packageDir: string, newVersion: string,
                skipIfDownloadFails: bool, release: string = "") =
  autoUpdaterWithFetcher(pkg, packageDir, newVersion, skipIfDownloadFails,
    release, proc(source, destination: string) =
      download(source, destination, raiseWhenFail = true))
