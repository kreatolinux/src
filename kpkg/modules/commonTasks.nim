import os
import config
import runparser

proc mv*(f: string, t: string): seq[string] =
    ## Moves files and directories and sends the list of files as a seq[string].
    var d: string
    var r: seq[string]

    setCurrentDir(f)
    
    for i in walkFiles("."):
        moveFile(i, t&"/"&i)

    for n in walkDirs("."):
       for i in walkDirRec("./"&n, {pcFile, pcLinkToFile, pcDir, pcLinkToDir}):
          d = t&"/"&splitFile(i).dir
          when not defined(release):
            echo "kpkg: debug: creating directory to "&d
            echo "kpkg: debug: going to move file/dir "&i&" to "&t&"/"&i
          
          createDir(d)

          if dirExists(i) and not dirExists(t&"/"&i):
            moveDir(i, t&"/"&i)
          
          if fileExists(i):  
            moveFile(i, t&"/"&i)
          r = r&i
    
    return r

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

