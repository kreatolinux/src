import os
import config
import runparser

proc mv*(f: string, t: string) =
    ## Moves files and directories.
    var d: string

    setCurrentDir(f)

    for i in walkFiles("."):
        moveFile(i, t&"/"&i)

    for i in walkDirRec(".", {pcFile, pcLinkToFile, pcDir, pcLinkToDir}):
        d = t&"/"&splitFile(i).dir
        when not defined(release):
            echo "kpkg: debug: creating directory to "&d
            echo "kpkg: debug: going to move file/dir "&i&" to "&t&"/"&i

        if dirExists(i) and not dirExists(t&"/"&i):
            moveDir(i, t&"/"&i)

        createDir(d)

        if fileExists(i):
            moveFile(i, t&"/"&i)

proc ctrlc*() {.noconv.} =
    for path in walkFiles("/var/cache/kpkg/archives/arch/"&hostCPU&"/*.partial"):
        removeFile(path)

    echo ""
    echo "kpkg: ctrl+c pressed, shutting down"
    quit(130)

proc printReplacesPrompt*(pkgs: seq[string], root: string) =
    ## Prints a replacesPrompt.
    for i in pkgs:
        for p in parse_runfile(findPkgRepo(i)&"/"&i).replaces:
            if dirExists(root&"/var/cache/kpkg/installed/"&p):
                echo "'"&i&"' replaces '"&p&"'"

