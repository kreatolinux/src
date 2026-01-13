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
import ../checksums
import ../libarchive
import ../downloader
import ../commonPaths

proc extractSources*(source: string, sourceDir: string) =
    ## Extracts a source archive
    if isEmptyOrWhitespace(source):
        return

    let filename = extractFilename(source)
    debug "trying to extract \"" & filename & "\""
    try:
        discard extract(filename)
    except Exception:
        debug "extraction failed, continuing"
        debug "exception: "&getCurrentExceptionMsg()

proc downloadSource*(url, filename, pkgName: string) =
    ## Downloads a source file or git repository, falling back to a mirror if necessary
    let mirror = getConfigValue("Options", "sourceMirror", "mirror.krea.to/sources")
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
            fatal("Invalid git URL format: " & url)
        let repoUrl = gitParts[1]
        let branch = if gitParts.len > 2: gitParts[2] else: "HEAD"
        let repoName = lastPathPart(repoUrl)
        if execCmd("git clone " & repoUrl & " " & repoName & " && cd " &
                repoName & " && git checkout " & branch) != 0:
            fatal("Git clone failed for: " & repoUrl)
        createSymlink(getCurrentDir() / repoName, filename)
    else:
        try:
            debug "downloader ran, filename: "&filename
            download(url, filename, raiseWhenFail = raiseWhenFail)
        except Exception:
            info "download failed through sources listed on the runFile, contacting the source mirror"
            download("https://" & mirror & "/" & pkgName & "/" &
                    extractFilename(url).strip(),

filename, raiseWhenFail = false)

proc verifyChecksum*(relativeFilename: string, filename, sourceUrl: string,
        sourceEntry: SourceEntry, sourceDir: string, localFile: bool) =
    ## Verifies the checksum of a downloaded file
    if sourceUrl.startsWith("git::"):
        # Skip checksum verification for Git sources
        return

    var actualDigest: string
    var expectedDigest: string
    var sumType: string

    # Try BLAKE2 checksum
    if not isEmptyOrWhitespace(sourceEntry.b2sum):
        expectedDigest = sourceEntry.b2sum
        sumType = "b2"

    # Try SHA-512 if BLAKE2 not available
    if sumType != "b2" and not isEmptyOrWhitespace(sourceEntry.sha512sum):
        expectedDigest = sourceEntry.sha512sum
        sumType = "sha512"

    # Try SHA-256 if neither BLAKE2 nor SHA-512 available
    if sumType != "sha512" and sumType != "b2" and not isEmptyOrWhitespace(
            sourceEntry.sha256sum):
        expectedDigest = sourceEntry.sha256sum
        sumType = "sha256"

    # Verify checksum (skip verification for local files explicitly marked as SKIP)
    if not (localFile and dirExists(filename)):
        actualDigest = getSum(filename, sumType)
        if expectedDigest != actualDigest:
            if not (localFile and expectedDigest == "SKIP"):
                removeFile(filename)
                error(sumType & "sum doesn't match for " & sourceUrl &
                    "\nExpected: '" & expectedDigest & "'\nActual: '" &
                    actualDigest & "'")
                quit(1)

    # Always add symlink to buildRoot/filename so local files are available
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
                for subPath in toSeq(walkDirRec(path.path, {pcFile,
                        pcLinkToFile, pcDir, pcLinkToDir})):
                    discard posix.chown(cstring(subPath), 999, 999)
            except:
                debug "Failed to set owner for " & path.path


proc sourceDownloader*(runf: runFile, pkgName: string, sourceDir: string,
        runFilePath: string) =
    ## Wrapper function for downloading and extracting sources
    debug "sourceDownloader ran, sourceDir: "&sourceDir&", runFilePath: "&runFilePath

    for sourceEntry in runf.sources:
        let source = sourceEntry.url
        debug "source: "&source
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

        verifyChecksum(filename, sourcePath, source, sourceEntry, sourceDir, isLocalFile)

        # Skip extraction for Git repositories as they're already in the correct format
        # And also skip localfiles
        if runf.extract and not (source.startsWith("git::") or isLocalFile):
            extractSources(sourcePath, sourceDir)


proc setSourceOwnership*(sourceDir: string) =
    ## Sets permissions and ownership (uid/gid 999) for source directory
    ## and all contents recursively.
    ##
    ## This prepares the source directory for building with proper
    ## permissions for the build user.

    setFilePermissions(sourceDir, {fpUserExec, fpUserWrite, fpUserRead,
            fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})
    discard posix.chown(cstring(sourceDir), 999, 999)

    for path in toSeq(walkDir(sourceDir)):
        if dirExists(path.path):
            setFilePermissions(path.path, {fpUserExec, fpUserWrite, fpUserRead,
                    fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})
        discard posix.chown(cstring(path.path), 999, 999)

        if dirExists(path.path):
            for subPath in toSeq(walkDirRec(path.path, {pcFile, pcLinkToFile,
                    pcDir, pcLinkToDir})):
                discard posix.chown(cstring(subPath), 999, 999)


proc countAndFindSourceFolders*(baseDir: string): tuple[count: int,
        folder: string] =
    ## Walks baseDir, counts directories, returns count and last folder path.
    ##
    ## Used for autocd logic - if exactly one folder exists, autocd will
    ## change into it.
    ##
    ## Returns:
    ##   count: Number of directories found
    ##   folder: Absolute path to the last directory found (or empty if none)

    result.count = 0
    result.folder = ""

    for item in toSeq(walkDir(baseDir)):
        debug "countAndFindSourceFolders: " & item.path
        if dirExists(item.path):
            result.folder = absolutePath(item.path)
            result.count = result.count + 1
            setFilePermissions(result.folder, {fpUserExec, fpUserWrite,
                    fpUserRead, fpGroupExec, fpGroupRead, fpOthersExec, fpOthersRead})
        discard posix.chown(cstring(result.folder), 999, 999)

        if dirExists(result.folder):
            for subPath in toSeq(walkDirRec(result.folder, {pcFile,
                    pcLinkToFile, pcDir, pcLinkToDir})):
                discard posix.chown(cstring(subPath), 999, 999)
