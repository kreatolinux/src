# chkupd v3 Arch backend
import std/[os, json, httpclient, uri, parsecfg, strutils]
import ../../../kpkg/modules/run3/run3
import ../[autoupdater, upstreamVersions]

type ArchResult* = object
  pkgname*, repo*, arch*, epoch*, pkgver*, pkgrel*: string

proc compareArchVersions(left, right: ArchResult): int =
  let epochCmp = compareUpstreamVersions(
    (if left.epoch.len == 0: "0" else: left.epoch),
    (if right.epoch.len == 0: "0" else: right.epoch))
  if epochCmp != 0: return epochCmp
  compareUpstreamVersions(left.pkgver, right.pkgver)

proc archVersion(item: ArchResult): string =
  (if item.epoch.len > 0 and item.epoch != "0": item.epoch & ":" else: "") & item.pkgver

proc field(node: JsonNode, name: string): string =
  if node.hasKey(name):
    if node[name].kind == JString: return node[name].getStr
    if node[name].kind == JInt: return $node[name].getInt

proc selectArchResult*(document: JsonNode, packageName: string): ArchResult =
  ## Select an exact package from stable Arch repos and supported arches.
  if document.kind != JObject or not document.hasKey("results") or
      document["results"].kind != JArray:
    raise newException(ValueError, "Arch response has no results array")
  for node in document["results"]:
    if node.kind != JObject: continue
    let candidate = ArchResult(pkgname: field(node, "pkgname"),
      repo: field(node, "repo"), arch: field(node, "arch"),
      epoch: field(node, "epoch"), pkgver: field(node, "pkgver"),
      pkgrel: field(node, "pkgrel"))
    if candidate.pkgname != packageName or
        candidate.repo notin ["Core", "Extra", "Multilib", "core", "extra", "multilib"] or
        candidate.arch notin ["x86_64", "any"] or candidate.pkgver.len == 0:
      continue
    if result.pkgname.len == 0 or
        compareArchVersions(candidate, result) > 0 or
        (compareArchVersions(candidate, result) == 0 and
         compareUpstreamVersions(candidate.pkgrel, result.pkgrel) > 0):
      result = candidate

proc archCheck*(package: string, repo: string, autoUpdate = false,
                skipIfDownloadFails = true, verbose = false) =
  let pkgName = lastPathPart(package)
  let packageDir = repo / pkgName
  let pkg = parseRun3(packageDir)
  var archPackage = pkg.getName()
  let cfgPath = packageDir / "chkupd.cfg"
  if fileExists(cfgPath):
    let cfg = loadConfig(cfgPath)
    archPackage = cfg.getSectionValue("arch", "package",
      cfg.getSectionValue("autoUpdater", "package", archPackage)).strip
  if archPackage.len == 0:
    raise newException(ValueError, "Arch package name is empty for " & pkgName)
  var client = newHttpClient(timeout = 30_000)
  defer: client.close()
  var response: string
  try:
    response = client.getContent("https://archlinux.org/packages/search/json/?name=" &
      encodeUrl(archPackage, usePlus = false))
  except CatchableError as e:
    raise newException(IOError, "Arch package request failed for '" & archPackage & "': " & e.msg)
  var document: JsonNode
  try: document = parseJson(response)
  except JsonParsingError as e:
    raise newException(ValueError, "Arch returned invalid JSON for '" & archPackage & "': " & e.msg)
  let selected = selectArchResult(document, archPackage)
  if selected.pkgname.len == 0:
    if verbose: echo "No exact stable Arch package found for '" & archPackage & "'."
    return

  let localVersion = pkg.getVersion()
  let localRelease = pkg.getRelease()
  let upstreamVersion = selected.pkgver # Never write Arch's epoch into run3 version.
  # Arch epoch/pkgrel select the best Arch record, but they are downstream
  # packaging metadata and must not rewrite or influence local run3 metadata.
  let versionNewer = compareUpstreamVersions(upstreamVersion, localVersion) > 0
  if verbose:
    echo "chkupd v3 Arch backend"
    echo "local version: " & localVersion & "-" & localRelease
    echo "remote version: " & archVersion(selected) & "-" & selected.pkgrel
  if versionNewer:
    echo "Package is not uptodate."
    if autoUpdate:
      autoUpdater(pkg, packageDir, upstreamVersion, skipIfDownloadFails)
  elif verbose:
    echo "Package is up-to-date."
