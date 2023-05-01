import cligen
include backends/repology

clCfg.version = "chkupd v3"

dispatchMulti(
        [
        repologyCheck, help = {
           "package": "Package name.",
           "repo": "Repository name.",
           "autoUpdate": "Autoupdate if older version is detected.",
           "skipIfDownloadFails": "Skip autoupdate if the newer version couldn't be downloaded."
        }
        ]
)
