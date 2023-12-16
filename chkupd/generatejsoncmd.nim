include json
import os

proc generateJson*(backend = "repology", repo: string, autoUpdate = true, output = "out.json") =
    ## Generates a build jsonfile
    type
        update = object
            package: string
            repository: string
            command: string
    
    var u: seq[update]

    let repoFullPath = absolutePath(repo)

    for i in walkFiles(repoFullPath&"/*/run"):
        let pkg = lastPathPart(i.parentDir)
        u = u&update(package: pkg, repository: repoFullPath, command: "chkupd "&backend&"Check --package="&pkg&" --repo="&repoFullPath&" --autoUpdate="&($autoUpdate))
    #u = u&update(package: "bash", repository: "/tmp/repo", command: "chkupd repologyCheck -p=bash -r=/tmp/repo")


    writeFile(output, $(%u))