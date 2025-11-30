import cligen
import checkcmd
import cleanupcmd
import generatejsoncmd

clCfg.version = "chkupd v3.2"

dispatchMulti(
        [
        check, help = {
           "package": "Package name. Supports wildcards: * matches any sequence, ? matches any single character.",
           "repo": "Repository name.",
           "backend": "Backend name. Defaults to repology",
           "autoUpdate": "Autoupdate if older version is detected.",
           "skipIfDownloadFails": "Skip autoupdate if the newer version couldn't be downloaded.",
           "verbose": "Enable verbose output."
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
