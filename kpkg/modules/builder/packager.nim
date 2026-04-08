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

proc createPackage*(actualPackage: string, pkg: runFile,
        kTarget: string): string =
  ## Creates a binary package from the build directory.
  var tarball = kpkgArchivesDir&"/system/"&kTarget

  createDir(tarball)

  tarball = tarball&"/"&actualPackage&"-"&pkg.versionString&".kpkg"

  # pkgInfo.ini
  var pkgInfo = newConfig()

  pkgInfo.setSectionKey("", "pkgVer", pkg.versionString)
  pkgInfo.setSectionKey("", "apiVer", ver)

  var depsInfo: string


  for dep in pkg.deps:

    if isEmptyOrWhitespace(dep):
      continue

    let depPkg = resolveDependencyPackage(dep)

    if depPkg.isNil:
      raise newException(CatchableError, "Failed to resolve dependency: " & dep)

    if isEmptyOrWhitespace(depsInfo):
      depsInfo = (dep&"#"&depPkg.version)
    else:
      depsInfo = depsInfo&" "&(dep&"#"&depPkg.version)

  pkgInfo.setSectionKey("", "depends", depsInfo)

  pkgInfo.writeConfig(kpkgBuildRoot&"/pkgInfo.ini")

  # pkgsums.ini
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

  try:
    createArchive(tarball, kpkgBuildRoot, format = "gnutar", filter = "gzip")
  except LibarchiveError as e:
    error "creating binary tarball failed: " & e.msg

  return tarball
