import os
import json
import strutils
import norm/[model, sqlite]
import std/options

type vulnerability* = ref object of Model
    cve*: string
    description*: string
    package*: string
    versionEndExcluding*: string

func newVulnerability*(cve = "", description = "", package = "", versionEndExcluding = ""): vulnerability =
  vulnerability(cve: cve, description: description, package: package, versionEndExcluding: versionEndExcluding)

proc updateVulns*(dbConn: DbConn, file: string, removeFileAfterwards = false): int =
    # Parses vulnerabilities. Creates a vulnerability database and returns the count.
    let json = parseJson(readFile(file))
    
    var counter: int
    for i in json["cve_items"]:
        counter = counter + 1
        
        var 
            cve: string
            description: string
            package: string
            versionEndExcluding: seq[string]
            cpeMatch: JsonNode
        
        try:
            cpeMatch = json["cve_items"][counter]["configurations"][0]["nodes"][0]["cpeMatch"]
        except Exception:
            continue
        
        try:
            package = cpeMatch[0]["criteria"].getStr().split(":")[4]
        except Exception:
            continue

        cve = json["cve_items"][counter]["id"].getStr()
        
        for i in json["cve_items"][counter]["descriptions"]:
            if i["lang"].getStr() == "en":
                description = i["value"].getStr()

        for i in 0..cpeMatch.len:
            try:
                versionEndExcluding = versionEndExcluding&cpeMatch[i]["versionEndExcluding"].getStr()
            except Exception:
                versionEndExcluding = versionEndExcluding&"false"
        
        var vulnFinal = newVulnerability(cve = cve, description = description, package = package, versionEndExcluding = versionEndExcluding.join("::"))
        dbConn.createTables(newVulnerability())
        dbConn.insert(vulnFinal)

    if removeFileAfterwards:
        removeFile(file)

    return counter

#[let vulns = updateVulns()
#echo "cveparse: '"&($vulns)&"' vulnerabilities parsed."
#var customersFoo = @[newVulnerability()]
dbConn.select(customersFoo, "vulnerability.package = ? LIMIT 10", "linux_kernel")

for i in customersFoo:
    echo i.cve
    echo i.package
    echo i.description
    echo i.versionEndExcluding
]#

