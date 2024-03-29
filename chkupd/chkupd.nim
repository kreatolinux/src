import cligen
import backends/repology
import backends/arch
import checkallcmd
import cleanupcmd
import jsontomdcmd
import generatejsoncmd

clCfg.version = "chkupd v3.1"

dispatchMulti(
        [
        repologyCheck, help = {
           "package": "Package name.",
           "repo": "Repository name.",
           "autoUpdate": "Autoupdate if older version is detected.",
           "skipIfDownloadFails": "Skip autoupdate if the newer version couldn't be downloaded."
        }
        ],
        [
        archCheck, help = {
           "package": "Package name.",
           "repo": "Repository name.",
           "autoUpdate": "Autoupdate if older version is detected.",
           "skipIfDownloadFails": "Skip autoupdate if the newer version couldn't be downloaded."
        }
        ],
        [
        checkAll, help = {
           "repo": "Repository name.",
           "backend": "Backend name. Defaults to repology",
           "autoUpdate": "Autoupdate if older version is detected.",
           "autoBuild": "Build packages on a seperate container each time.",
           "jsonPath": "Json output location (defaults to chkupd.json)"
        }
        ],
        [
        cleanUp, help = {
          "verbose": "Enable verbose output.",
          "dir": "Set directory of archives (eg. /var/cache/kpkg/archives/arch/amd64)."
        }
        ],
        [
         jsonToMd
        ],
        [
         generateJson, suppress = @["ignorePackages", "instance"]
        ]
)
