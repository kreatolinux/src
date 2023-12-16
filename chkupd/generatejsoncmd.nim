include json
import os

proc generateJson*(backend = "repology", repo: string, limit = 256, autoUpdate = true, output = "out.json") =
    ## Generates a build jsonfile
    type
        update = object
            package: string
            repository: string
            command: string
    
    var u: seq[update]

    let repoFullPath = absolutePath(repo)
    var count: int

    for i in walkFiles(repoFullPath&"/*/run"):
        
        if count >= limit and limit > 0:
            break

        let pkg = lastPathPart(i.parentDir)
        u = u&update(package: pkg, repository: repoFullPath, command: "chkupd "&backend&"Check --package="&pkg&" --repo="&repoFullPath&" --autoUpdate="&($autoUpdate))
        count = count + 1

    let res = %*
        {
            "include": %u
        }

    writeFile(output, $(res))