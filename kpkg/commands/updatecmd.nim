import os
import sequtils
import strutils
import ../../common/logging
import ../modules/config
import ../modules/gitutils

proc update*(repo = "",
    path = "", branch = "master"): int =
  ## Update repositories.

  if not isAdmin():
    error("you have to be root for this action.")
    quit(1)

  let repodirs = getConfigValue("Repositories", "repoDirs")
  let repolinks = getConfigValue("Repositories", "repoLinks")

  let repoList: seq[tuple[dir: string, link: string]] = zip(repodirs.split(
          " "), repolinks.split(" "))

  for i in repoList:
    if not updateOrCloneRepo(i.dir, i.link):
      error("failed to update repositories!")
      quit(1)

  if path != "" and repo != "":
    info "cloning "&path&" from "&repo&"::"&branch

    let repoUrl = if branch != "master": repo & "::" & branch else: repo
    if not cloneRepo(repo, path, branch):
      error("failed to clone repository!")
      quit(1)

    if not (repo in repolinks and path in repodirs):
      if branch != "master":
        setConfigValue("Repositories", "repoLinks",
                repolinks&" "&repo&"::"&branch)
        setConfigValue("Repositories", "repoDirs", repodirs&" "&path)
      else:
        setConfigValue("Repositories", "repoLinks", repolinks&" "&repo)
        setConfigValue("Repositories", "repoDirs", repodirs&" "&path)


  info "updated all repositories"
  return 0
