include json
import os
import ../kpkg/modules/runparser

type
    Update = object
        packages: string

proc generateJson*(repo: string, limit = 256, splitIfLimit = true, output = "out.json", ignorePackages = @[Update(packages: "")], instance = 1) =
    ## Generates a build jsonfile

    var updateList: seq[Update]

    let repoFullPath = absolutePath(repo)
    var count: int

    for i in walkFiles(repoFullPath&"/*/run"):
        
        let pkg = lastPathPart(i.parentDir)
        
        var willContinue: bool

        for i in ignorePackages:
            if pkg in i.packages.split(" "):
                willContinue = true

        if count >= limit and limit > 0:
            if splitIfLimit:
                let outputSplit = output.split(".")
                generateJson(repo, limit, splitIfLimit, output = outputSplit[0]&"-"&($(instance + 1))&"."&outputSplit[1], ignorePackages = ignorePackages&updateList, instance = (instance + 1))
            
            break
        
        for i in updateList:
                if pkg in i.packages.split(" "):
                    willContinue = true
        
        if willContinue:
            continue

        var deps = parseRunfile(i.parentDir).deps.join(" ") # Not full dependency list ofc, but good enough for now 
        
        if not isEmptyOrWhitespace(deps):
            deps = deps&" "&pkg
        else:
            deps = pkg
        
        updateList = updateList&Update(packages: deps)
        count = count + 1
    
    echo "Generated '"&($count)&"' json parts at '"&output&"'"

    let res = %*
        {
            "include": %updateList
        }

    writeFile(output, $(res))
