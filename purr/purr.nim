import cligen
import sequtils
import parsecfg
import os
import options
include ../src/nyaa/modules/logger
include ../src/nyaa/modules/config
include ../src/nyaa/build
include ../src/nyaa/update
include ../src/nyaa/upgrade
include ../src/nyaa/remove
include ../src/nyaa/info

proc ok(message: string) =
    styledEcho "[", styleBright, fgGreen, " OK ", resetStyle, "] "&message 

proc warn(message: string) =
    styledEcho "[", styleBright, fgYellow, " WARN ", resetStyle, "] "&message 

proc error(message: string) =
    styledEcho "[", styleBright, fgRed, " ERROR ", resetStyle, "] "&message
    quit(1)

proc genFiles(tmpdir: string) =
    ## Generates files required for the utility to function.
    ok("Files successfully generated.")
    discard existsOrCreateDir(tmpdir)
    discard existsOrCreateDir(tmpdir&"/root")
    discard existsOrCreateDir(tmpdir&"/root/etc")

proc purr(tests="all", tmpdir="/tmp/purr") =
    ## nyaa3's testing utility.
    
    if not isAdmin():
        error("You have to be root to run the tests.")

    removeDir("/tmp/purr")
    genFiles(tmpdir)    

    # Test update
    # TODO: remove repo from config when successful
    discard update("https://github.com/kreatolinux/purr-test-repo.git", "/tmp/purr/test")
    if dirExists(tmpdir&"/test"):
        ok("update test completed succesfully")
    else:
        error("update test failed")

    # Test build
    discard build(yes=true, root=tmpdir&"/root", packages=toSeq(["purr"]), offline = true)
    if fileExists("/testfile"):
        ok("build test completed successfully")
    else:
        error("build test failed")

    # Test remove
    discard remove(packages=toSeq(["purr"]), yes = true, root = "/tmp/purr/root")
    if not fileExists(tmpdir&"root/testfile"):
        ok("remove test completed succesfully")
    else:
        error("remove test failed")

    discard info(toSeq(["purr"]))
    ok("info test completed")

    # Test install_bin (and the functions it uses)
    #install_bin(["purr"], "http://localhost:8080")

dispatch purr
