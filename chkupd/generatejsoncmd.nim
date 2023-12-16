include json
import os
import ../kpkg/modules/runparser


proc generateJson*(backend = "repology", repo: string, limit = 256, output = "out.json") =
    ## Generates a build jsonfile
    type
        update = object
            packages: string
            repository: string
    
    var updateList: seq[update]

    let repoFullPath = absolutePath(repo)
    var count: int

    for i in walkFiles(repoFullPath&"/*/run"):
        
        let pkg = lastPathPart(i.parentDir)

        if count >= limit and limit > 0:
            break
        
        var deps = parseRunfile(i.parentDir).deps.join(" ") # Not full dependency list ofc, but good enough for now
        
        var willContinue: bool

        for i in updateList:
                if pkg in i.packages.split(" "):
                    willContinue = true
        
        if willContinue:
            continue

        if not isEmptyOrWhitespace(deps):
            deps = deps&" "&pkg
        else:
            deps = pkg
        
        updateList = updateList&update(packages: deps, repository: repoFullPath)
        count = count + 1
    
    echo count

    let res = %*
        {
            "include": %updateList
        }

    writeFile(output, $(res))