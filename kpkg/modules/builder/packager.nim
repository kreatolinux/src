import os
import strutils
import sequtils
import parsecfg
import ../../../common/logging
import ../sqlite
import ../runparser
import ../checksums
import ../libarchive
import ../commonPaths
import ../../../common/version

proc resolveDependencyPackage*(dep: string,
                              roots: seq[string] = @[kpkgEnvPath,
                                  kpkgOverlayPath & "/upperDir",
                                      "/"]): Package =
  ## Resolve dependency package metadata from known roots.
  ##
  ## The fallback to "/" is important when a dependency is satisfied by
  ## an already-installed package (including replacements such as ninja/samurai).
  for root in roots:
    if packageExists(dep, root):
      return getPackage(dep, root)

  when defined(release):
    error "Dependency '" & dep & "' not found while generating binary package"
  else:
    debug "Dependency '" & dep & "' not found while generating binary package"

  raise newException(CatchableError, "Dependency '" & dep & "' not found")

proc resolveDepsInfo*(pkg: runFile): string =
  ## Resolve all dependencies and return a formatted depsInfo string.
  for dep in pkg.deps:
    if isEmptyOrWhitespace(dep):
      continue

    let depPkg = resolveDependencyPackage(dep)

    if isEmptyOrWhitespace(result):
      result = (dep&"#"&depPkg.version)
    else:
      result = result&" "&(dep&"#"&depPkg.version)

proc writePkgSums*() =
  ## Generate and write pkgsums.ini for the current build root.
  var dict = newConfig()

  for file in toSeq(walkDirRec(kpkgBuildRoot, {pcFile, pcLinkToFile, pcDir,
          pcLinkToDir})):
    if "pkgInfo.ini" == relativePath(file, kpkgBuildRoot): continue
    if dirExists(file) or symlinkExists(file):
      dict.setSectionKey("", "\""&relativePath(file, kpkgBuildRoot)&"\"", "")
    else:
      dict.setSectionKey("", "\""&relativePath(file, kpkgBuildRoot)&"\"",
              getSum(file, "b2"))

  dict.writeConfig(kpkgBuildRoot&"/pkgsums.ini")

proc createPackage*(actualPackage: string, pkg: runFile,
        kTarget: string, resolveDeps: bool = true,
        tarballPath: string = ""): string =
  ## Creates a binary package from the build directory.
  ##
  ## If resolveDeps is false, the tarball is created *without* dependency
  ## metadata so that it can be installed first (registering the package
  ## in the database) and dependency resolution is deferred to a later
  ## finalizePackageDeps call.
  ##
  ## If tarballPath is non-empty, the tarball is written to that exact path
  ## instead of the default archives directory.
  var tarball =
    if tarballPath.len > 0:
      tarballPath
    else:
      let dir = kpkgArchivesDir&"/system/"&kTarget
      createDir(dir)
      dir&"/"&actualPackage&"-"&pkg.versionString&".kpkg"

  if tarballPath.len > 0:
    createDir(parentDir(tarballPath))

  # pkgInfo.ini
  var pkgInfo = newConfig()

  pkgInfo.setSectionKey("", "pkgVer", pkg.versionString)
  pkgInfo.setSectionKey("", "apiVer", ver)

  let depsInfo = if resolveDeps: resolveDepsInfo(pkg) else: ""

  pkgInfo.setSectionKey("", "depends", depsInfo)

  pkgInfo.writeConfig(kpkgBuildRoot&"/pkgInfo.ini")

  writePkgSums()

  try:
    createArchive(tarball, kpkgBuildRoot, format = "gnutar", filter = "gzip")
  except LibarchiveError as e:
    error "creating binary tarball failed: " & e.msg
    raise

  return tarball

proc finalizePackageDeps*(actualPackage: string, pkg: runFile,
        kTarget: string, outputPath: string = "") =
  ## Resolves dependencies and writes the tarball with complete metadata.
  ##
  ## Must be called AFTER installPkg has registered the current package and
  ## all its dependency packages in the database.
  ##
  ## If outputPath is non-empty, the final tarball is written to that exact
  ## path. Otherwise it overwrites the default archives location.
  let tarball =
    if outputPath.len > 0:
      outputPath
    else:
      kpkgArchivesDir&"/system/"&kTarget&"/"&actualPackage&"-" &
              pkg.versionString&".kpkg"

  createDir(parentDir(tarball))

  let depsInfo = resolveDepsInfo(pkg)

  # Update pkgInfo.ini in buildRoot
  var pkgInfo = newConfig()
  pkgInfo.setSectionKey("", "pkgVer", pkg.versionString)
  pkgInfo.setSectionKey("", "apiVer", ver)
  pkgInfo.setSectionKey("", "depends", depsInfo)
  pkgInfo.writeConfig(kpkgBuildRoot&"/pkgInfo.ini")

  writePkgSums()

  try:
    createArchive(tarball, kpkgBuildRoot, format = "gnutar", filter = "gzip")
  except LibarchiveError as e:
    error "recreating binary tarball with dependencies failed: " & e.msg
    raise
