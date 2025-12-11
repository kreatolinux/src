import os
import strutils
include json
import ../kpkg/modules/run3/run3

type
    Update = object
        packages: string

proc generateJson*(repo: string, limit = 256, splitIfLimit = true, output = "out.json", ignorePackages = @[Update(packages: "")], instance = 1) =
    ## Generates a build jsonfile

    # Glibc and musl should be built/upgraded seperately from the rest
    # Especially glibc as upgrading it can create a lot of issues (GNU moment)
    # Musl shouldn't cause problems, but it's better to be safe than sorry
    const specialPackages = @["glibc", "musl"] 

    var updateList: seq[Update]

    let repoFullPath = absolutePath(repo)
    var count: int
    for i in walkFiles(repoFullPath&"/*/run3"):
        
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
        
        
        if isEmptyOrWhitespace(pkg):
            continue

        if willContinue:
            continue

        var deps = parseRun3(i.parentDir).getDepends().join(" ") # Not full dependency list ofc, but good enough for now 
        
        if not isEmptyOrWhitespace(deps):
            deps = deps&" "&pkg
        else:
            deps = pkg

        updateList = updateList&Update(packages: deps)
        count = count + 1
    
    echo "Generated '"&($count)&"' json parts at '"&output&"'"
    
    for package in specialPackages:
        updateList = updateList&Update(packages: package)

    let res = %*
        {
            "include": %updateList
        }

    writeFile(output, $(res))
