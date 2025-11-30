import os
import parsecfg
import backends/arch
import backends/repology
import backends/githubReleases

proc matchesWildcard*(text: string, pattern: string): bool =
    ## Check if text matches a wildcard pattern.
    ## Supports * (matches any sequence) and ? (matches any single character).
    var textIdx = 0
    var patternIdx = 0
    var starIdx = -1
    var matchIdx = -1
    
    while textIdx < text.len:
        if patternIdx < pattern.len and (pattern[patternIdx] == '?' or pattern[patternIdx] == text[textIdx]):
            textIdx += 1
            patternIdx += 1
        elif patternIdx < pattern.len and pattern[patternIdx] == '*':
            starIdx = patternIdx
            matchIdx = textIdx
            patternIdx += 1
        elif starIdx != -1:
            patternIdx = starIdx + 1
            matchIdx += 1
            textIdx = matchIdx
        else:
            return false
    
    while patternIdx < pattern.len and pattern[patternIdx] == '*':
        patternIdx += 1
    
    return patternIdx == pattern.len

proc check*(package: string, repo: string, backend: string, autoUpdate = true, skipIfDownloadFails = false, verbose = false) =
    ## Check if the given package is up-to-date or not, and update it.
    ## Supports wildcards: * matches any sequence, ? matches any single character.
    
    # Check if package name contains wildcards
    if '*' in package or '?' in package:
        # Wildcard pattern detected - find all matching packages
        let repoFullPath = absolutePath(repo)
        var matchedPackages: seq[string] = @[]
        
        # Scan repository for all packages
        for runFile in walkFiles(repoFullPath&"/*/run"):
            let pkg = lastPathPart(runFile.parentDir)
            if matchesWildcard(pkg, package):
                matchedPackages.add(pkg)
        
        if matchedPackages.len == 0:
            echo "No packages found matching pattern: " & package
            return
        
        # Check each matching package
        for matchedPkg in matchedPackages:
            echo "Checking package: " & matchedPkg
            check(matchedPkg, repo, backend, autoUpdate, skipIfDownloadFails, verbose)
        return
    
    # No wildcards - proceed with normal check
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
            repologyCheck(package, repo, autoUpdate, skipIfDownloadFails, verbose)
        of "arch":
            archCheck(package, repo, autoUpdate, skipIfDownloadFails, verbose)
        of "githubReleases":
            if githubReleasesRepo == "":
                echo "githubReleasesRepo is not set in chkupd.cfg"
                quit(1)
            githubReleasesCheck(package, repo, githubReleasesRepo, autoUpdate, skipIfDownloadFails, trimString, verbose)
        else:
            echo "Unknown backend: "&actualBackend
            quit(1)
