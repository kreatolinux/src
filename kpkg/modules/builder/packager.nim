import os
import strutils
import sequtils
import parsecfg
import ../logger
import ../sqlite
import ../runparser
import ../checksums
import ../processes
import ../commonPaths
import ../../../common/version

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

    var pkg: Package

    try:
      if packageExists(dep, kpkgEnvPath):
        pkg = getPackage(dep, kpkgEnvPath)
      elif packageExists(dep, kpkgOverlayPath&"/upperDir"):
        pkg = getPackage(dep, kpkgOverlayPath&"/upperDir/")
      else:
        when defined(release):
          err "Unknown error occured while generating binary package"
        else:
          debug "Unknown error occured while generating binary package"
          raise getCurrentException()

    except CatchableError:
      raise
    if isEmptyOrWhitespace(depsInfo):
      depsInfo = (dep&"#"&pkg.version)
    else:
      depsInfo = depsInfo&" "&(dep&"#"&pkg.version)

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

  if execCmdKpkg("bsdtar -czf "&tarball&" -C "&kpkgBuildRoot&" .").exitCode != 0:
    err "creating binary tarball failed"
  #createArchive(tarball, kpkgBuildRoot)

  #writeFile(tarball&".sum.b2", getSum(tarball, "b2"))

  return tarball
