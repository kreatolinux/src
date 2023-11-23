import os
import json
import strutils
import norm/[model, sqlite]
import std/options

type vulnerability = ref object of Model
    cve: string
    description: string
    package: string
    versionEndExcluding: string

func newVulnerability(cve = "", description = "", package = "", versionEndExcluding = ""): vulnerability =
  vulnerability(cve: cve, description: description, package: package, versionEndExcluding: versionEndExcluding)

let dbConn = open("vulns.db", "", "", "")

proc updateVulns*(file="CVE-2023.json"): int =
    # Parses vulnerabilities. Creates a vulnerability database and returns the count.
    let json = parseJson(readFile(file))
    
    var counter: int
    for i in json["cve_items"]:
        counter = counter + 1
        var 
            cve: string
            description: string
            package: string
            versionEndExcluding: string 
        
        try:
            package = json["cve_items"][counter]["configurations"][0]["nodes"][0]["cpeMatch"][0]["criteria"].getStr().split(":")[4]
        except Exception:
            continue

        cve = json["cve_items"][counter]["id"].getStr()
        
        for i in json["cve_items"][counter]["descriptions"]:
            if i["lang"].getStr() == "en":
                description = i["value"].getStr()

        try:
            versionEndExcluding = json["cve_items"][counter]["configurations"][0]["nodes"][0]["cpeMatch"][0]["versionEndExcluding"].getStr()
        except Exception:
            versionEndExcluding = "false"
        
        var vulnFinal = newVulnerability(cve = cve, description = description, package = package, versionEndExcluding = versionEndExcluding)
        dbConn.createTables(newVulnerability())
        dbConn.insert(vulnFinal)

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

