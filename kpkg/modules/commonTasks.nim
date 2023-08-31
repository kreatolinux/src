import os
import config
import logger
import strutils
import parsecfg
import runparser

proc getInit*(root: string): string =
  ## Returns the init system.
  try:
    return loadConfig(root&"/etc/kreato-release").getSectionValue("Core", "init")
  except CatchableError:
    err("couldn't load "&root&"/etc/kreato-release")

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

        if fileExists(i) or symlinkExists(i):
            moveFile(i, t&"/"&i)

proc printPackagesPrompt*(packages: string, yes: bool, no: bool) =
    ## Prints the packages summary prompt.

    echo "Packages: "&packages

    var output: string

    if yes:
        output = "y"
    elif no:
        output = "n"
    else:
        stdout.write "Do you want to continue? (y/N) "
        output = readLine(stdin)

    if output.toLower() != "y":
        echo "kpkg: exiting"
        quit(0)

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

