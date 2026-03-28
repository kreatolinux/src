#[
  Commit context management for commit-based builds and installs.
  
  Provides templates that handle:
  - Parsing commit from package specifiers
  - Finding which repo contains the commit
  - Caching runfiles from HEAD before checkout
  - Checking out the commit
  
  Two templates:
  - withCommitContext: For builds (stays checked out, restores in finally)
  - withInstallCommitContexts: For installs (gets version, restores immediately)
]#

import tables
import strutils
import ../gitutils
import ../runparser
import ../commonTasks
import ../../../common/logging

type
  CommitContext* = object
    commit*: string
    commitRepo*: string
    headRunfileCache*: Table[string, runFile]
    packagesWithCommit*: seq[string]

  InstallCommitContext* = object
    commit*: string
    commitRepo*: string
    versionAtCommit*: string
    pkgName*: string
    headRunfileCache*: Table[string, runFile]

proc parseCommitFromPackages*(packages: seq[string]): (string, seq[string]) =
  var commit = ""
  var packagesWithCommit: seq[string] = @[]

  for pkg in packages:
    let pkgInfo = parsePkgInfo(pkg)
    if pkgInfo.commit != "":
      if commit == "":
        commit = pkgInfo.commit
      elif commit != pkgInfo.commit:
        error("All packages must use the same commit hash. Found '" & commit &
            "' and '" & pkgInfo.commit & "'")
        quit(1)
      packagesWithCommit.add(pkgInfo.name)

  return (commit, packagesWithCommit)

template withCommitContext*(packages: seq[string], body: untyped) =
  ## Context manager for commit-based builds.
  ## Stays checked out during body execution, restores in finally block.

  let (parsedCommit, packagesWithCommit) = parseCommitFromPackages(packages)

  var commitCtx {.inject.}: CommitContext
  commitCtx.commit = parsedCommit
  commitCtx.packagesWithCommit = packagesWithCommit

  if parsedCommit == "":
    body
  else:
    info "Building " & packagesWithCommit.join(", ") & " from commit " & parsedCommit

    commitCtx.commitRepo = findRepoWithCommit(parsedCommit)
    if commitCtx.commitRepo == "":
      error("Commit '" & parsedCommit & "' not found in any configured repository")
      quit(1)

    info "Found commit in repo: " & commitCtx.commitRepo

    commitCtx.headRunfileCache = cacheRepoRunfiles(commitCtx.commitRepo)
    debug "Cached " & $commitCtx.headRunfileCache.len & " runfiles from HEAD"

    let originalRef = getCurrentRef(commitCtx.commitRepo)

    let buildState = CommitBuildState(
      repoPath: commitCtx.commitRepo,
      originalRef: originalRef,
      commit: parsedCommit
    )
    saveCommitBuildState(buildState)

    if not checkoutCommit(commitCtx.commitRepo, parsedCommit):
      error("Failed to checkout commit '" & parsedCommit & "'")
      quit(1)
    info "Checked out commit " & parsedCommit

    try:
      body
    finally:
      info "Restoring repo to " & originalRef
      discard restoreRepo(commitCtx.commitRepo, originalRef)
      clearCommitBuildState()

proc getInstallCommitContext*(pkg: string): InstallCommitContext =
  ## Get commit context for a single package install.
  ## Restores repo immediately after parsing version.

  let pkgInfo = parsePkgInfo(pkg)

  if pkgInfo.commit == "":
    debug "commitctx: No commit specified for '" & pkg & "'"
    return InstallCommitContext(pkgName: pkgInfo.name)

  let commit = pkgInfo.commit
  let commitRepo = findRepoWithCommit(commit)

  if commitRepo == "":
    error("Commit '" & commit & "' not found in any repository")
    quit(1)

  info "commitctx: Getting version for '" & pkgInfo.name & "' at commit '" &
      commit & "'"

  let headCache = cacheRepoRunfiles(commitRepo)
  debug "commitctx: Cached " & $headCache.len & " runfiles from HEAD"

  let originalRef = getCurrentRef(commitRepo)

  let buildState = CommitBuildState(
    repoPath: commitRepo,
    originalRef: originalRef,
    commit: commit
  )
  saveCommitBuildState(buildState)

  if not checkoutCommit(commitRepo, commit):
    error("Failed to checkout commit '" & commit & "'")
    quit(1)

  let runf = parseRunfile(pkgInfo.repo & "/" & pkgInfo.name)
  let versionAtCommit = runf.versionString

  discard restoreRepo(commitRepo, originalRef)
  clearCommitBuildState()

  info "commitctx: Version at commit '" & commit & "' for '" & pkgInfo.name &
      "' is " & versionAtCommit

  return InstallCommitContext(
    commit: commit,
    commitRepo: commitRepo,
    versionAtCommit: versionAtCommit,
    pkgName: pkgInfo.name,
    headRunfileCache: headCache
  )

proc getInstallCommitContexts*(packages: seq[string]): Table[string,
    InstallCommitContext] =
  ## Get commit contexts for multiple packages for install.

  result = initTable[string, InstallCommitContext]()

  for pkg in packages:
    let pkgInfo = parsePkgInfo(pkg)
    let ctx = getInstallCommitContext(pkg)
    result[pkgInfo.name] = ctx

  var firstCommit = ""
  for name, ctx in result:
    if ctx.commit != "":
      if firstCommit == "":
        firstCommit = ctx.commit
      elif firstCommit != ctx.commit:
        error("All packages must use the same commit hash. Found '" &
            firstCommit & "' and '" & ctx.commit & "'")
        quit(1)

proc hasAnyCommit*(contexts: Table[string, InstallCommitContext]): bool =
  for _, ctx in contexts:
    if ctx.commit != "":
      return true
  return false

template withInstallCommitContexts*(packages: seq[string], contextsVar: untyped,
    body: untyped) =
  ## Context manager for commit-based install operations.
  ## Injects contextsVar: Table[string, InstallCommitContext] into body.

  let contextsVar {.inject.} = getInstallCommitContexts(packages)
  body
