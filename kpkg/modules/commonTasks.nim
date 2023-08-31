import os
import config
import runparser

proc mv*(f: string, t: string) =
    ## Moves files and directories.
    for kind, path in walkDir(f&"/."):
      if kind == pcFile or kind == pcLinkToFile:
        moveFile(path, t&"/"&lastPathPart(path))
      elif kind == pcDir or kind == pcLinkToDir:
        moveDir(path, t&"/"&lastPathPart(path))

    return

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

