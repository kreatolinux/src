## Git utilities for commit-based builds in kpkg
##
## Provides functions for:
## - Finding which repo contains a commit
## - Checking out repos to specific commits
## - Restoring repos to their original state
## - Caching runfiles before checkout

import os
import osproc
import tables
import strutils
import parsecfg
import ../../common/logging
import config
import runparser

const
  commitBuildLockPath* = "/var/cache/kpkg/commit-build.lock"

type
  CommitBuildState* = object
    repoPath*: string
    originalRef*: string
    commit*: string

proc isValidHexString(s: string): bool =
  ## Check if string is a valid hex string (potential git commit hash)
  if s.len < 4 or s.len > 40:
    return false
  for c in s:
    if c notin {'0'..'9', 'a'..'f', 'A'..'F'}:
      return false
  return true

proc isCommitHash*(s: string): bool =
  ## Check if a string looks like a git commit hash
  ## Commit hashes are 4-40 character hex strings
  ## Version strings typically contain dots, dashes with numbers, etc.
  return isValidHexString(s)

proc findRepoWithCommit*(commit: string): string =
  ## Search all configured repos for a commit
  ## Returns the repo path if found, empty string if not

  let repoDirs = getConfigValue("Repositories", "repoDirs").split(" ")

  for repoDir in repoDirs:
    if not dirExists(repoDir):
      continue

    # Use git cat-file to check if commit exists in this repo
    let (output, exitCode) = execCmdEx("git -C " & quoteShell(repoDir) &
                                        " cat-file -t " & quoteShell(commit) & " 2>/dev/null")

    if exitCode == 0 and output.strip() == "commit":
      debug "gitutils: Found commit '" & commit & "' in repo '" & repoDir & "'"
      return repoDir

  debug "gitutils: Commit '" & commit & "' not found in any repository"
  return ""

proc getCurrentRef*(repoPath: string): string =
  ## Get the current branch name or commit hash of a repo
  ## Returns branch name if on a branch, or commit hash if in detached HEAD state

  # Try to get branch name first
  let (branchOutput, branchExitCode) = execCmdEx(
    "git -C " & quoteShell(repoPath) & " symbolic-ref --short HEAD 2>/dev/null")

  if branchExitCode == 0 and branchOutput.strip().len > 0:
    let branch = branchOutput.strip()
    debug "gitutils: Current ref for '" & repoPath & "' is branch '" & branch & "'"
    return branch

  # Fallback to commit hash (detached HEAD)
  let (commitOutput, commitExitCode) = execCmdEx(
    "git -C " & quoteShell(repoPath) & " rev-parse HEAD 2>/dev/null")

  if commitExitCode == 0:
    let commit = commitOutput.strip()
    debug "gitutils: Current ref for '" & repoPath & "' is commit '" & commit & "'"
    return commit

  error "gitutils: Failed to get current ref for '" & repoPath & "'"
  return ""

proc resolveCommit*(repoPath: string, commitish: string): string =
  ## Resolve a partial commit hash or ref to a full commit hash

  let (output, exitCode) = execCmdEx(
    "git -C " & quoteShell(repoPath) & " rev-parse " & quoteShell(commitish) & " 2>/dev/null")

  if exitCode == 0:
    return output.strip()

  return ""

proc checkoutCommit*(repoPath: string, commit: string): bool =
  ## Checkout a repo to a specific commit (detached HEAD)
  ## Returns true on success

  debug "gitutils: Checking out '" & repoPath & "' to commit '" & commit & "'"

  let exitCode = execCmd("git -C " & quoteShell(repoPath) &
                         " checkout " & quoteShell(commit) & " 2>/dev/null")

  if exitCode == 0:
    debug "gitutils: Successfully checked out to '" & commit & "'"
    return true
  else:
    error "gitutils: Failed to checkout '" & repoPath & "' to commit '" &
        commit & "'"
    return false

proc restoreRepo*(repoPath: string, originalRef: string): bool =
  ## Restore a repo to its original branch or commit
  ## Returns true on success

  debug "gitutils: Restoring '" & repoPath & "' to '" & originalRef & "'"

  let exitCode = execCmd("git -C " & quoteShell(repoPath) &
                         " checkout " & quoteShell(originalRef) & " 2>/dev/null")

  if exitCode == 0:
    debug "gitutils: Successfully restored to '" & originalRef & "'"
    return true
  else:
    error "gitutils: Failed to restore '" & repoPath & "' to '" & originalRef & "'"
    return false

proc saveCommitBuildState*(state: CommitBuildState) =
  ## Save commit build state to lockfile for crash recovery

  var cfg = newConfig()
  cfg.setSectionKey("CommitBuild", "repoPath", state.repoPath)
  cfg.setSectionKey("CommitBuild", "originalRef", state.originalRef)
  cfg.setSectionKey("CommitBuild", "commit", state.commit)

  try:
    createDir(parentDir(commitBuildLockPath))
    cfg.writeConfig(commitBuildLockPath)
    debug "gitutils: Saved commit build state to " & commitBuildLockPath
  except:
    warn "gitutils: Failed to save commit build state"

proc loadCommitBuildState*(): CommitBuildState =
  ## Load commit build state from lockfile
  ## Returns empty state if no lockfile exists

  if not fileExists(commitBuildLockPath):
    return CommitBuildState()

  try:
    let cfg = loadConfig(commitBuildLockPath)
    result.repoPath = cfg.getSectionValue("CommitBuild", "repoPath")
    result.originalRef = cfg.getSectionValue("CommitBuild", "originalRef")
    result.commit = cfg.getSectionValue("CommitBuild", "commit")
    debug "gitutils: Loaded commit build state from " & commitBuildLockPath
  except:
    warn "gitutils: Failed to load commit build state"
    result = CommitBuildState()

proc clearCommitBuildState*() =
  ## Remove the commit build state lockfile

  if fileExists(commitBuildLockPath):
    try:
      removeFile(commitBuildLockPath)
      debug "gitutils: Cleared commit build state"
    except:
      warn "gitutils: Failed to clear commit build state"

proc hasCommitBuildState*(): bool =
  ## Check if there's a pending commit build state
  return fileExists(commitBuildLockPath)

proc recoverFromCommitBuild*(): bool =
  ## Attempt to recover from a crashed commit build
  ## Returns true if recovery was performed

  if not hasCommitBuildState():
    return false

  let state = loadCommitBuildState()

  if state.repoPath.len == 0 or state.originalRef.len == 0:
    clearCommitBuildState()
    return false

  info "Recovering from interrupted commit build..."
  info "Restoring '" & state.repoPath & "' to '" & state.originalRef & "'"

  if restoreRepo(state.repoPath, state.originalRef):
    clearCommitBuildState()
    info "Repository restored successfully"
    return true
  else:
    error "Failed to restore repository - manual intervention may be required"
    error "Run: git -C " & state.repoPath & " checkout " & state.originalRef
    return false

proc cacheRepoRunfiles*(repoPath: string): Table[string, runFile] =
  ## Cache all package runfiles in a repo at current state
  ## Call this BEFORE checking out to a commit to preserve HEAD versions

  result = initTable[string, runFile]()

  debug "gitutils: Caching runfiles from '" & repoPath & "'"

  for entry in walkDir(repoPath):
    if entry.kind != pcDir:
      continue

    let pkgName = lastPathPart(entry.path)

    # Skip hidden directories and non-package directories
    if pkgName.startsWith("."):
      continue

    let runfilePath = entry.path & "/run"
    if not fileExists(runfilePath):
      continue

    try:
      let rf = parseRunfile(entry.path, removeLockfileWhenErr = false)
      result[pkgName] = rf
      debug "gitutils: Cached runfile for '" & pkgName & "' (version: " &
          rf.versionString & ")"
    except:
      debug "gitutils: Failed to parse runfile for '" & pkgName & "', skipping"

  debug "gitutils: Cached " & $result.len & " runfiles from '" & repoPath & "'"

proc getPackageVersionAtHead*(pkgName: string, headCache: Table[string,
    runFile]): string =
  ## Get the version of a package from the HEAD cache
  ## Returns empty string if not found

  if pkgName in headCache:
    return headCache[pkgName].versionString
  return ""

proc packageExistsAtHead*(pkgName: string, headCache: Table[string,
    runFile]): bool =
  ## Check if a package exists in the HEAD cache
  return pkgName in headCache

proc pullRepo*(repoPath: string): bool =
  ## Pull latest changes for a git repository.
  ## Returns true on success.

  debug "gitutils: Pulling " & repoPath
  let exitCode = execCmd("git -C " & quoteShell(repoPath) & " pull")
  if exitCode == 0:
    debug "gitutils: Pull successful for " & repoPath
    return true
  else:
    error "gitutils: Failed to pull " & repoPath
    return false

proc cloneRepo*(url: string, destPath: string, branch = ""): bool =
  ## Clone a git repository to the specified path.
  ## If branch is specified (and not empty), checkout that branch after cloning.
  ## Returns true on success.

  debug "gitutils: Cloning " & url & " to " & destPath

  let cloneExitCode = execCmd("git clone " & quoteShell(url) & " " & quoteShell(destPath))
  if cloneExitCode != 0:
    error "gitutils: Failed to clone " & url
    return false

  if branch != "" and branch != "master" and branch != "main":
    debug "gitutils: Checking out branch " & branch
    let checkoutExitCode = execCmd("git -C " & quoteShell(destPath) &
        " checkout " & quoteShell(branch))
    if checkoutExitCode != 0:
      error "gitutils: Failed to checkout branch " & branch
      return false

  debug "gitutils: Clone successful"
  return true

proc updateOrCloneRepo*(repoPath: string, repoUrl: string, branch = ""): bool =
  ## Update an existing repo or clone it if it doesn't exist.
  ## Handles url::branch format in repoUrl.
  ## Returns true on success.

  if dirExists(repoPath):
    return pullRepo(repoPath)
  else:
    # Parse url::branch format if present
    var url = repoUrl
    var branchToUse = branch
    if "::" in repoUrl:
      let parts = repoUrl.split("::")
      url = parts[0]
      branchToUse = parts[1]

    info "Repository at " & repoPath & " not found, cloning..."
    return cloneRepo(url, repoPath, branchToUse)
