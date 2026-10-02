# chkupd v3 Repology backend
import std/[json, strutils, os, httpclient, uri, parsecfg]
import ../../../kpkg/modules/run3/run3
import ../[autoupdater, upstreamVersions]
import ../../../common/version

proc selectRepologyVersion*(entries: JsonNode): string =
  ## Select the greatest stable version from `newest` entries. Ties and input
  ## order cannot affect the result.
  if entries.kind != JArray:
    raise newException(ValueError, "Repology response must be an array")
  for entry in entries:
    if entry.kind != JObject: continue
    if not entry.hasKey("status") or not entry.hasKey("version"): continue
    if entry["status"].kind != JString or entry["version"].kind != JString: continue
    let candidate = entry["version"].getStr.strip
    if entry["status"].getStr == "newest" and candidate.len > 0 and
        not isPrerelease(candidate) and
        (result.len == 0 or compareUpstreamVersions(candidate, result) > 0):
      result = candidate

proc repologyCheck*(package: string, repo: string, autoUpdate = false,
                skipIfDownloadFails = true, verbose = false) =
  let pkgName = lastPathPart(package)
  let packageDir = repo / pkgName
  let pkg = parseRun3(packageDir)
  var project = pkg.getName()
  let cfgPath = packageDir / "chkupd.cfg"
  if fileExists(cfgPath):
    let cfg = loadConfig(cfgPath)
    # Accept the backend-specific key; autoUpdater is retained as a convenient
    # explicit override location for existing configuration layouts.
    project = cfg.getSectionValue("repology", "project",
      cfg.getSectionValue("autoUpdater", "project", project)).strip
  if project.len == 0:
    raise newException(ValueError, "Repology project name is empty for " & pkgName)

  var client = newHttpClient(timeout = 30_000, userAgent = "Klinux chkupd/" & ver &
    " (issuetracker: https://github.com/kreatolinux/src/issues)")
  defer: client.close()
  var response: string
  try:
    response = client.getContent("https://repology.org/api/v1/project/" &
      encodeUrl(project, usePlus = false))
  except CatchableError as e:
    raise newException(IOError, "Repology request failed for project '" &
      project & "': " & e.msg)
  var entries: JsonNode
  try: entries = parseJson(response)
  except JsonParsingError as e:
    raise newException(ValueError, "Repology returned invalid JSON for project '" &
      project & "': " & e.msg)
  let upstream = selectRepologyVersion(entries)
  if upstream.len == 0:
    if verbose: echo "Repology has no stable 'newest' version for project '" & project & "'."
    return

  let local = pkg.getVersion()
  let outdated = compareUpstreamVersions(upstream, local) > 0
  if verbose:
    echo "chkupd v3 Repology backend"
    echo "Repology project: " & project
    echo "Current package version: " & local
    echo "Latest version found: " & upstream
  if autoUpdate:
    if not outdated:
      echo "Package is already up-to-date."
    else:
      echo "Package is outdated. Updating..."
      autoUpdater(pkg, packageDir, upstream, skipIfDownloadFails)
  else:
    if verbose or outdated: echo "Latest version found: " & upstream
    if outdated:
      echo "Package is outdated (current: " & local & ", latest: " & upstream & ")"
    elif verbose: echo "Package is up-to-date (version: " & local & ")"
