# chkupd v3 GitHub releases backend
import std/[json, strutils, os, httpclient, uri, sequtils]
import regex
import ../../../kpkg/modules/run3/run3
import ../[autoupdater, upstreamVersions]
import ../../../common/version

proc normalizeGithubTag*(tag: string; configuredPrefix = ""): string =
  ## Remove the configured prefix once, and only at the beginning.
  result = tag.strip
  if configuredPrefix.len > 0 and result.startsWith(configuredPrefix):
    result = result[configuredPrefix.len .. ^1]
  result = result.strip

proc releaseForPython*(release, pythonVersion: string): string =
  ## Keep exactly one trailing interpreter version across Python upgrades.
  if release.endsWith("-" & pythonVersion): return release
  let pythonSuffix = re2("-[0-9]+\\.[0-9]+(?:\\.[0-9]+)?(?:[A-Za-z]+[0-9]*)?$")
  release.replace(pythonSuffix, "") & "-" & pythonVersion

proc githubReleasesCheck*(package: string, repo: string,
                githubReleasesRepo: string, autoUpdate = false,
                skipIfDownloadFails = true, trimString = "", verbose = false) =
  let pkgName = lastPathPart(package)
  let packageDir = repo / pkgName
  var client = newHttpClient(timeout = 30_000, userAgent = "Klinux chkupd/" & ver &
    " (issuetracker: https://github.com/kreatolinux/src/issues)")
  defer: client.close()
  let repoParts = githubReleasesRepo.split('/')
  if repoParts.len != 2 or repoParts.anyIt(it.len == 0):
    raise newException(ValueError, "GitHub repository must be owner/name: " & githubReleasesRepo)
  let encodedRepo = repoParts.mapIt(encodeUrl(it, usePlus = false)).join("/")
  var response: string
  try:
    response = client.getContent("https://api.github.com/repos/" &
      encodedRepo & "/releases/latest")
  except CatchableError as e:
    raise newException(IOError, "GitHub releases request failed for " &
      githubReleasesRepo & ": " & e.msg)

  var document: JsonNode
  try: document = parseJson(response)
  except JsonParsingError as e:
    raise newException(ValueError, "GitHub returned invalid JSON for " &
      githubReleasesRepo & ": " & e.msg)
  if document.kind != JObject or not document.hasKey("tag_name") or
      document["tag_name"].kind != JString:
    raise newException(ValueError, "GitHub response for " & githubReleasesRepo &
      " has no string tag_name")
  let upstream = normalizeGithubTag(document["tag_name"].getStr, trimString)
  if upstream.len == 0:
    raise newException(ValueError, "GitHub release tag became empty after normalization")

  let pkg = parseRun3(packageDir)
  let local = pkg.getVersion()
  var pkgRelease = pkg.getRelease()
  if "python" in pkg.getDepends():
    let pythonVersion = parseRun3(repo / "python").getVersion()
    pkgRelease = releaseForPython(pkgRelease, pythonVersion)

  let outdated = compareUpstreamVersions(upstream, local) > 0
  if verbose:
    echo "chkupd v3 GitHub Releases backend"
    echo "Repository: " & githubReleasesRepo
    echo "Latest release tag: " & upstream
  if autoUpdate:
    if not outdated and pkg.getRelease() == pkgRelease:
      echo "Package is already up-to-date."
    else:
      echo "Package is outdated. Updating..."
      autoUpdater(pkg, absolutePath(packageDir),
        (if outdated: upstream else: local), skipIfDownloadFails, pkgRelease)
  else:
    if verbose or outdated: echo "Latest version found: " & upstream
    if outdated:
      echo "Package is outdated (current: " & local & ", latest: " & upstream & ")"
    elif verbose: echo "Package is up-to-date (version: " & local & ")"
