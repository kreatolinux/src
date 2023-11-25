import os
import json

proc jsonToMd*(json: seq[string]) =
    ## Converts chkupd json to markdown.
    
    echo "# chkupd automatic update report\n"
    
    let jsonParsed = parseJson(readFile(json[0]))

    echo ($jsonParsed[0]["successfulPkgCount"])&" packages updated successfully. "&($jsonParsed[0]["failedPkgCount"])&" packages failed to autoupdate.\n"

    echo "# Packages that failed to build"
    
    for i in jsonParsed[0]["failedBuildPackages"]:
        echo "* "&lastPathPart(i.getStr())
    
    echo "\n# Packages that failed to autoupdate"
    
    for i in jsonParsed[0]["failedUpdPackages"]:
        echo "* "&lastPathPart(i.getStr())