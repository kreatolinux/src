#[
  Commit context management for commit-based builds.
  
  Provides a template that handles:
  - Parsing commit from package specifiers
  - Finding which repo contains the commit
  - Caching runfiles from HEAD before checkout
  - Checking out the commit
  - Restoring the repo in finally block
]#

import tables
import strutils
import ../gitutils
import ../runparser
import ../commonTasks
import ../../../common/logging

type
  CommitContext* = object
    ## Context for commit-based builds, passed to the body of withCommitContext
    commit*: string
    commitRepo*: string
    headRunfileCache*: Table[string, runFile]
    packagesWithCommit*: seq[string]

proc parseCommitFromPackages*(packages: seq[string]): (string, seq[string]) =
  ## Parse commit hash from package specifiers.
  ## Returns (commit, packagesWithCommit).
  ## Errors if packages have different commits.
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
  ##
  ## Handles:
  ## - Parsing commit from package specifiers
  ## - Finding which repo contains the commit
  ## - Caching runfiles from HEAD before checkout
  ## - Checking out the commit
  ## - Restoring the repo in finally block
  ##
  ## Injects `commitCtx: CommitContext` into the body.
  ## If no commit is specified, commitCtx fields are empty and body runs normally.

  let (parsedCommit, packagesWithCommit) = parseCommitFromPackages(packages)

  var commitCtx {.inject.}: CommitContext
  commitCtx.commit = parsedCommit
  commitCtx.packagesWithCommit = packagesWithCommit

  if parsedCommit == "":
    # No commit specified, just run the body
    body
  else:
    # Commit-based build: setup context
    info "Building " & packagesWithCommit.join(", ") & " from commit " & parsedCommit

    commitCtx.commitRepo = findRepoWithCommit(parsedCommit)
    if commitCtx.commitRepo == "":
      error("Commit '" & parsedCommit & "' not found in any configured repository")
      quit(1)

    info "Found commit in repo: " & commitCtx.commitRepo

    # Cache runfiles from HEAD before checkout
    commitCtx.headRunfileCache = cacheRepoRunfiles(commitCtx.commitRepo)
    debug "Cached " & $commitCtx.headRunfileCache.len & " runfiles from HEAD"

    # Save original ref for restoration
    let originalRef = getCurrentRef(commitCtx.commitRepo)

    # Save state for crash recovery
    let buildState = CommitBuildState(
      repoPath: commitCtx.commitRepo,
      originalRef: originalRef,
      commit: parsedCommit
    )
    saveCommitBuildState(buildState)

    # Checkout the commit
    if not checkoutCommit(commitCtx.commitRepo, parsedCommit):
      error("Failed to checkout commit '" & parsedCommit & "'")
      quit(1)
    info "Checked out commit " & parsedCommit

    try:
      body
    finally:
      # Restore repo to original state
      info "Restoring repo to " & originalRef
      discard restoreRepo(commitCtx.commitRepo, originalRef)
      clearCommitBuildState()
