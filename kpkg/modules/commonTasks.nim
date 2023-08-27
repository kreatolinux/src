import os
import config
import runparser

proc printReplacesPrompt*(pkgs: seq[string], root: string) =
    ## Prints a replacesPrompt.
    for i in pkgs:
        for p in parse_runfile(findPkgRepo(i)&"/"&i).replaces:
            if dirExists(root&"/var/cache/kpkg/installed/"&p):
                echo "'"&i&"' replaces '"&p&"'"

