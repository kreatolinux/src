import os
import strutils

proc provides*(files: seq[string]) =
    ## List packages that contains a file.
    setCurrentDir("/")
    for file in files:
        for listFiles in walkFiles("/var/cache/kpkg/installed/*/list_files"):
            for line in lines listFiles:
                if relativePath(file, "/") in line:
                    var res = line
                    normalizePath(res)
                    echo absolutePath(res)&" @ "&relativePath(listFiles, "/var/cache/kpkg/installed/").replace("/list_files", "")
                