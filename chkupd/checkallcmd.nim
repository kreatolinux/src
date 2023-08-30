import os
import json
import osproc
import sequtils
import backends/arch
import backends/repology
import ../kpkg/modules/runparser

proc checkAll*(repo: string, backend = "repology", autoUpdate = true,
        autoBuild = true, jsonPath = "chkupd.json") =
    ## Checks all packages, and updates them automatically.
    var failedUpdPackages: seq[string]
    var failedBuildPackages: seq[string]
    var pkgCount: int
    let cmdStr = "docker run -e QEMU_CPU=max --rm -v "&repo&":/etc/kpkg/repos/main -v /var/cache/kpkg/archives:/var/cache/kpkg/archives ghcr.io/kreatolinux/builder-gnu:latest kpkg build -u -y "

    case backend:
        of "repology":
            # this sounds stupid but i couldnt think of anything else lol
            var pkgFailed = true
            if autoBuild:
                if execShellCmd("docker pull ghcr.io/kreatolinux/builder-gnu:latest") != 0:
                    echo "couldn't pull docker container, exiting"
                    quit(1)

            for i in toSeq(walkDirs(repo&"/*")):
                let run = parse_runfile(repo&"/"&lastPathPart(i))

                if run.noChkupd:
                    let cmd = execCmdEx(cmdStr&lastPathPart(i))
                    if cmd.exitCode != 0:
                        writeFile("failed-log-"&lastPathPart(i)".log", cmd.output)
                        failedBuildPackages = failedBuildPackages&i
                        echo "couldnt build "&i
                    continue


                if lastPathPart(i) == ".git" or lastPathPart(i) == ".github" or
                        lastPathPart(i) == "builder-essentials":
                    continue

                echo "trying to update "&i
                try:
                    repologyCheck(package = i, repo = repo,
                            autoUpdate = autoUpdate,
                            skipIfDownloadFails = false)
                    pkgFailed = false
                    echo "updating "&i&" successful"
                    if not autoBuild:
                        pkgCount = pkgCount+1
                except CatchableError:
                    failedUpdPackages = failedUpdPackages&i
                    echo "couldnt update "&i

                if not pkgFailed and autoBuild:
                    let cmd = execCmdEx(cmdStr&lastPathPart(i))
                    if cmd.exitCode != 0:
                        writeFile("failed-log-"&lastPathPart(i)".log", cmd.output)
                        failedBuildPackages = failedBuildPackages&i
                        echo "couldnt build "&i
                    else:
                        pkgCount = pkgCount+1
        of "arch":
            # this sounds stupid but i couldnt think of anything else lol
            var pkgFailed = true

            for i in toSeq(walkDirs(repo&"/*")):

                let run = parse_runfile(repo&"/"&lastPathPart(i))

                if run.noChkupd:
                    let cmd = execCmdEx(cmdStr&lastPathPart(i))
                    if cmd.exitCode != 0:
                        writeFile("failed-log-"&lastPathPart(i)".log", cmd.output)
                        failedBuildPackages = failedBuildPackages&i
                        echo "couldnt build "&i
                    continue


                if lastPathPart(i) == ".git" or lastPathPart(i) == ".github" or
                        lastPathPart(i) == "builder-essentials":
                    continue

                echo "trying to update "&i
                try:
                    archCheck(package = i, repo = repo, autoUpdate = autoUpdate,
                            skipIfDownloadFails = false)
                    pkgFailed = false
                    echo "updating "&i&" successful"
                except CatchableError:
                    failedUpdPackages = failedUpdPackages&i
                    echo "couldnt update "&i

                if not pkgFailed and autoBuild:
                    let cmd = execCmdEx(cmdStr&lastPathPart(i))
                    if cmd.exitCode != 0:
                        writeFile("failed-log-"&lastPathPart(i)".log", cmd.output)
                        failedBuildPackages = failedBuildPackages&i
                        echo "couldnt build "&i

        else:
            echo "Not supported"

    var json = %*
        [
            {
                "successfulPkgCount": pkgCount,
                "failedPkgCount": failedBuildPackages.len+failedUpdPackages.len,
                "failedBuildPackages": failedBuildPackages,
                "failedUpdPackages": failedUpdPackages
            }
        ]

    writeFile(jsonPath, $json)
