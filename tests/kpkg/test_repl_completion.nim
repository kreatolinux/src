import unittest
import ../../kpkg/commands/repl

suite "REPL tab completion":
  let repositoryPackages = @["bash", "base", "curl"]
  let installedPackages = @["bash", "glibc"]

  test "completes top-level commands and run3 statements":
    check "get" in replCompletionCandidates("", repositoryPackages,
        installedPackages)
    check replCompletionCandidates("ge", repositoryPackages,
        installedPackages) == @["get"]
    check replCompletionCandidates("pri", repositoryPackages,
        installedPackages) == @["print"]

  test "completes dotted query roots":
    check replCompletionCandidates("get dep", repositoryPackages,
        installedPackages) == @["get depends"]
    check replCompletionCandidates("set con", repositoryPackages,
        installedPackages) == @["set config"]

  test "completes package names and dependency query suffixes":
    check replCompletionCandidates("get depends.ba", repositoryPackages,
        installedPackages) == @[
          "get depends.base", "get depends.bash"]
    check replCompletionCandidates("get depends.bash.i", repositoryPackages,
        installedPackages) == @["get depends.bash.install"]
    check replCompletionCandidates("get depends.bash.install.g",
        repositoryPackages, installedPackages) == @[
          "get depends.bash.install.graph"]

  test "uses installed packages for database queries":
    check replCompletionCandidates("get db.package.gl", repositoryPackages,
        installedPackages) == @["get db.package.glibc"]
    check replCompletionCandidates("get db.package.glibc.v", repositoryPackages,
        installedPackages) == @["get db.package.glibc.version"]

  test "completes config sections and keys case-insensitively":
    check replCompletionCandidates("get config.rep", repositoryPackages,
        installedPackages) == @["get config.Repositories"]
    check replCompletionCandidates("set config.Repositories.repoL",
        repositoryPackages, installedPackages) == @[
          "set config.Repositories.repoLinks"]
