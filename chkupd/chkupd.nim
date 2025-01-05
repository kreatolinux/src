import cligen
import backends/repology
import backends/arch
import checkcmd
import cleanupcmd
import generatejsoncmd

clCfg.version = "chkupd v3.2"

dispatchMulti(
        [
        check, help = {
           "package": "Package name.",
           "repo": "Repository name.",
           "backend": "Backend name. Defaults to repology",
           "autoUpdate": "Autoupdate if older version is detected.",
           "skipIfDownloadFails": "Skip autoupdate if the newer version couldn't be downloaded."
        }
        ],
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
        cleanUp, help = {
          "verbose": "Enable verbose output.",
          "dir": "Set directory of archives (eg. /var/cache/kpkg/archives/arch/amd64)."
        }
        ],
        [
         generateJson, suppress = @["ignorePackages", "instance"]
        ]
)
