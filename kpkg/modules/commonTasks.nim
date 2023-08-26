import os
import config
import runparser

proc printReplacesPrompt*(pkgs: seq[string]) =
    ## Prints a replacesPrompt.
    for i in pkgs:
        for p in parse_runfile(findPkgRepo(i)&"/"&i).replaces:
            if dirExists("/var/cache/kpkg/installed/"&p):
                echo "'"&i&"' replaces '"&p&"'"

