import os
import parsecfg
import backends/arch
import backends/repology
import backends/githubReleases

proc check*(package: string, repo: string, backend: string, autoUpdate = true, skipIfDownloadFails = false) =
    ## Check if the given package is up-to-date or not, and update it.
    
    var actualBackend = backend
    var githubReleasesRepo = ""
    var trimString = ""


    # check if package/chkupd.cfg exists
    if fileExists(absolutePath(repo&"/"&package)&"/chkupd.cfg"):
        let cfg = loadConfig(absolutePath(repo&"/"&package)&"/chkupd.cfg")
        actualBackend = cfg.getSectionValue("autoUpdater", "mechanism", backend)
        if actualBackend == "githubReleases":
            githubReleasesRepo = cfg.getSectionValue("githubReleases", "repo", "")

        trimString = cfg.getSectionValue("autoUpdater", "trimString", "")
    
        
    case actualBackend:
        of "repology":
            repologyCheck(package, repo, autoUpdate, skipIfDownloadFails)
        of "arch":
            archCheck(package, repo, autoUpdate, skipIfDownloadFails)
        of "githubReleases":
            if githubReleasesRepo == "":
                echo "githubReleasesRepo is not set in chkupd.cfg"
                quit(1)
            githubReleasesCheck(package, repo, githubReleasesRepo, autoUpdate, skipIfDownloadFails, trimString)
        else:
            echo "Unknown backend: "&actualBackend
            quit(1)
