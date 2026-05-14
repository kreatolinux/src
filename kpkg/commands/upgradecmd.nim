import os
import strutils
import buildcmd
import installcmd
import ../modules/config
import ../modules/sqlite
import ../../common/logging
import ../modules/lockfile
import ../modules/runparser
import ../modules/processes
import ../modules/staleprocs

proc upgrade*(root = "/",
        builddir = "/tmp/kpkg/build", srcdir = "/tmp/kpkg/srcdir", yes = false,
                no = false, exclude: seq[string] = @[],
                disableExcludes: bool = false) =
  ## Upgrade packages.

  setDisableExcludes(disableExcludes)
  addCliExcludePatterns(exclude)

  isKpkgRunning()
  checkLockfile()

  var packages: seq[string]
  var repo: string

  for i in getListPackages(root):

    let pkg = lastPathPart(i)
    var localPkg: Package
    try:
      localPkg = getPackage(i, root)
    except CatchableError:
      fatal("Unknown error while reading installed package")

    var isAReplacesPackage: bool

    for r in localPkg.replaces.split("!!k!!"):
      if r == pkg:
        isAReplacesPackage = true

    if isAReplacesPackage:
      continue

    if localPkg.name in getConfigValue("Upgrade", "dontUpgrade").split(" "):
      info "skipping "&localPkg.name&": selected to not upgrade in kpkg.conf"
      continue

    repo = findPkgRepo(pkg)
    if isEmptyOrWhitespace(repo):
      warn "skipping "&localPkg.name&": not found in available repositories"
      continue

    let repoName = lastPathPart(repo)
    if isExcluded(pkg, repoName):
      info "skipping "&pkg&": excluded in kpkg.conf"
      continue

    when declared(localPkg.epoch):
      let epoch_local = epoch

    var upstreamPkg: runFile
    try:
      upstreamPkg = parseRunfile(repo&"/"&pkg)
    except CatchableError:
      fatal("Unknown error while reading package on repository, possibly broken repo?")

    if localPkg.version < upstreamPkg.version or localPkg.release <
        upstreamPkg.release or (localPkg.epoch != "no" and
                localPkg.epoch < upstreamPkg.epoch):
      packages = packages&pkg

  if packages.len == 0 and isEmptyOrWhitespace(packages.join("")):
    info("done")
    quit(0)

  if parseBool(getConfigValue("Upgrade", "buildByDefault", "false")):
    discard build(yes = yes, no = no, packages = packages, root = root,
            isUpgrade = true)
  else:
    discard install(packages, root, yes = yes, no = no, isUpgrade = true,
            exclude = exclude, disableExcludes = disableExcludes)

  staleprocs.printStaleWarning()

  info("done")
