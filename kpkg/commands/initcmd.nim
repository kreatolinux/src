import os
import strutils
import parsecfg
import ../modules/isolation
import ../modules/commonPaths
import ../modules/logger

proc sandbox*() =
    ## Initializes a sandbox.
    if dirExists(kpkgEnvPath):
        try:
            removeDir(kpkgEnvPath)
        except:
            discard umountOverlay(silentMode = true)
            removeDir(kpkgEnvPath)

    createEnv("/") 

proc package*(repo: string, package: string, release = "1", version: string, sources = "", depends = "", add = "build,package") =
    ## Initializes an empty package.
    var res = "NAME=\""&package&"\"\n"
    res = res&"VERSION=\""&version&"\"\n"
    res = res&"RELEASE=\""&release&"\"\n"
    res = res&"SOURCES=\""&sources&"\"\n"
    res = res&"DEPENDS=\""&depends&"\"\n" 
    res = res&"DESCRIPTION=\""&sources&"\"\n"

    for f in add.split(","):
        res = res&"\n"&f&"() {\n"
        res = res&" # Put commands here \n}\n"
    
    echo res
    

proc system*() =
    ## Initializes a new system.
    echo "wip"

proc override*(packages: seq[string], extraArguments = "", cflags = "", cxxflags = "", sourceMirror = "", binaryMirrors = "", ccache = false) =
    ## Initializes a new kpkg override.
    # runFile part of the overrides are not supported as that is too much work.
    if isEmptyOrWhitespace(packages.join("")):
        err("please enter packages", false)

    var dict = newConfig()
    
    if not isEmptyOrWhitespace(extraArguments):
        dict.setSectionKey("Flags", "extraArguments", extraArguments)
    
    if not isEmptyOrWhitespace(cflags):
        dict.setSectionKey("Flags", "cflags", cflags)
    
    if not isEmptyOrWhitespace(cxxflags):
        dict.setSectionKey("Flags", "cxxflags", cxxflags)
    
    if not isEmptyOrWhitespace(sourceMirror):
        dict.setSectionKey("Mirror", "sourceMirror", sourceMirror)
    
    if not isEmptyOrWhitespace(binaryMirrors):
        dict.setSectionKey("Mirror", "binaryMirrors", binaryMirrors)
    
    dict.setSectionKey("Other", "ccache", $ccache)

    createDir("/etc/kpkg/override")
    
    for package in packages:
        dict.writeConfig("/etc/kpkg/override/"&package&".conf")
