import os
import config
import runparser

proc mv*(f: string, t: string): seq[string] =
    ## Moves files and directories and sends the list of files as a seq[string].
    var d: string
    var r: seq[string]

    setCurrentDir(f)

    for i in walkDirRec("."):
      d = t&"/"&splitFile(i).dir
      if dirExists(d):
        when not defined(release):
          echo "kpkg: debug: "&d&" dir exists"
          echo "kpkg: debug: creating directory to "&d
          echo "kpkg: debug: going to move file "&i&" to "&t&"/"&i
        createDir(d)
        moveFile(i, t&"/"&i)
      else:
        when not defined(release):
          echo "kpkg: debug: moveDir from "&i&" to "&d
        moveDir(i, d)
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

