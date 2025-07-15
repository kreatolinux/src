#[
This module contains functions for handling source code operations
in the builder-ng module.

It includes the following functions:
    - sourceDownloader
    - extractSources
    - downloadSource
    - verifyChecksum
    - setSourcePermissions
]#

import os
import posix
import osproc
import sequtils
import strutils
import ../logger
import ../config
import ../runparser
import ../processes
import ../checksums
import ../libarchive
import ../downloader
import ../commonPaths

proc extractSources*(sources: string, sourceDir: string) =
    ## Extracts source archives
    for source in sources.split(" "):
        if isEmptyOrWhitespace(source):
            continue
            
        let filename = extractFilename(source)
        debug "trying to extract \"" & filename & "\""
        try:
            discard extract(filename)
        except Exception:
            debug "extraction failed, continuing"
            debug "exception: "&getCurrentExceptionMsg()

proc downloadSource*(url, filename, pkgName: string) =
    ## Downloads a source file or git repository, falling back to a mirror if necessary
    let mirror = getConfigValue("Options", "sourceMirror", "mirror.kreato.dev/sources")
    var raiseWhenFail = true
    
    try:
        if not parseBool(mirror):
            raiseWhenFail = false
    except Exception:
        discard

    if url.startsWith("git::"):
        # Handle git repository
        let gitParts = url.split("::")
        if gitParts.len < 2:
            err("Invalid git URL format: " & url)
        let repoUrl = gitParts[1]
        let branch = if gitParts.len > 2: gitParts[2] else: "HEAD"
        let repoName = lastPathPart(repoUrl)
        if execCmd("git clone " & repoUrl & " " & repoName & " && cd " & repoName & " && git checkout " & branch) != 0:
            err("Git clone failed for: " & repoUrl)
        createSymlink(getCurrentDir() / repoName, filename)
    else:
        try:
            debug "downloader ran, filename: "&filename
            download(url, filename, raiseWhenFail = raiseWhenFail)
        except Exception:
            info "download failed through sources listed on the runFile, contacting the source mirror"
            download("https://" & mirror & "/" & pkgName & "/" & extractFilename(url).strip(), 
                    filename, raiseWhenFail = false)

proc verifyChecksum*(filename, sourceUrl: string, runf: runFile, sourceIndex: int, sourceDir: string, localFile: bool) =
    ## Verifies the checksum of a downloaded file
    if sourceUrl.startsWith("git::"):
        # Skip checksum verification for Git sources 
        return

    var actualDigest: string
    var expectedDigest: string
    var sumType: string
    
    # Try BLAKE2 checksum
    try:
        expectedDigest = runf.b2sum.split(" ")[sourceIndex]
        if not isEmptyOrWhitespace(expectedDigest):
            sumType = "b2"
    except Exception:
        discard
    
    # Try SHA-512 if BLAKE2 not available
    if sumType != "b2":
        try:
            expectedDigest = runf.sha512sum.split(" ")[sourceIndex]
            if not isEmptyOrWhitespace(expectedDigest):
                sumType = "sha512"
        except Exception:
            discard
    
    # Try SHA-256 if neither BLAKE2 nor SHA-512 available
    if sumType != "sha512" and sumType != "b2":
        try:
            expectedDigest = runf.sha256sum.split(" ")[sourceIndex]
            if not isEmptyOrWhitespace(expectedDigest):
                sumType = "sha256"
        except Exception:
            err("runFile doesn't have proper checksums", false)
    
    # Verify checksum
    if not (localFile and dirExists(filename)):
        actualDigest = getSum(filename, sumType)
        if expectedDigest != actualDigest:
            if localFile and expectedDigest == "SKIP":
                return
            removeFile(filename)
            err(sumType & "sum doesn't match for " & sourceUrl & 
                "\nExpected: '" & expectedDigest & "'\nActual: '" & actualDigest & "'", false)

    # Add symlink to buildRoot/filename
    createSymlink(filename, sourceDir&"/"&lastPathPart(filename))

proc setSourcePermissions*() =
    ## Sets proper permissions for all source directories and their contents
    for path in toSeq(walkDir(".")):
        if dirExists(path.path):
            debug "Setting permissions for " & path.path
            setFilePermissions(path.path, {fpUserExec, fpUserWrite, fpUserRead, 
                                          fpGroupExec, fpGroupRead, 
                                          fpOthersExec, fpOthersRead})
            
            try:
                discard posix.chown(cstring(path.path), 999, 999)
                # Set permissions for all files in the directory
                for subPath in toSeq(walkDirRec(path.path, {pcFile, pcLinkToFile, pcDir, pcLinkToDir})):
                    discard posix.chown(cstring(subPath), 999, 999)
            except:
                debug "Failed to set owner for " & path.path


proc sourceDownloader*(runf: runFile, pkgName: string, sourceDir: string, runFilePath: string) =
    ## Wrapper function for downloading and extracting sources
    var i = 0

    for source in runf.sources.split(" "):
        var filename: string
        if source.startsWith("git::"): 
            filename = lastPathPart(source.split("::")[1]) 
        else: 
            filename = extractFilename(source)
        var sourcePath = kpkgSourcesDir & "/" & pkgName & "/" & filename
        let localPath = runFilePath & "/" & source
        var isLocalFile = false
        debug "sourcePath: "&sourcePath
        debug "localPath: "&localPath

        # Check if the source is a local file or directory
        if fileExists(localPath) or dirExists(localPath):
            isLocalFile = true
            debug "source is a local file or directory: " & localPath
            sourcePath = localPath
        else:
            debug "source is not a local file or directory, using sourcePath: " & sourcePath


        
        if not isLocalFile:
            downloadSource(source, sourcePath, pkgName)

        verifyChecksum(sourcePath, source, runf, i, sourceDir, isLocalFile)
        
        # Skip extraction for Git repositories as they're already in the correct format
        # And also skip localfiles
        if runf.extract and not (source.startsWith("git::") or isLocalFile):
            extractSources(sourcePath, sourceDir)

        i += 1
