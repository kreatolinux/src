import logger
import strutils

type runFile* = object
    pkg*: string
    sources*: string
    version*: string
    release*: string
    buildAsRoot*: bool
    sha256sum*: string
    epoch*: string
    versionString*: string
    conflicts*: seq[string]
    deps*: seq[string]
    bdeps*: seq[string]

proc parse_runfile*(path: string, removeLockfileWhenErr = true): runFile =
    ## Parse an runfile.

    var vars: seq[string]
    var ret: runFile

    try:
        for i in lines path&"/run":
            vars = i.split("=")
            case vars[0]:
                of "NAME":
                    ret.pkg = vars[1].multiReplace(
                    ("\"", ""),
                    ("'", "")
                    )
                of "SOURCES":
                    ret.sources = vars[1]
                of "VERSION":
                    ret.version = vars[1].multiReplace(
                    ("\"", ""),
                    ("'", "")
                    )
                of "BUILD_AS_ROOT":
                    ret.buildAsRoot = parseBool(vars[1].multiReplace(
                    ("\"", ""),
                    ("'", "")
                    ))
                of "RELEASE":
                    ret.release = vars[1].multiReplace(
                    ("\"", ""),
                    ("'", "")
                    )
                of "EPOCH":
                    ret.epoch = vars[1].multiReplace(
                    ("\"", ""),
                    ("'", "")
                    )
                of "SHA256SUM":
                    ret.sha256sum = vars[1]
                of "CONFLICTS":
                    ret.conflicts = vars[1].split(" ")
                of "DEPENDS":
                    ret.deps = vars[1].split(" ")
                of "BUILD_DEPENDS":
                    ret.deps = vars[1].split(" ")
            if "()" in vars[0]:
                break
    except CatchableError:
        err(path&" doesn't seem to have a runfile. possibly a broken package?", removeLockfileWhenErr)

    when declared(ret.epoch):
        ret.versionString = ret.version&"-"&ret.release&"-"&ret.epoch
    else:
        ret.versionString = ret.version&"-"&ret.release
        ret.epoch = "no"

    ret.sources = ret.sources.multiReplace(
    ("$NAME", ret.pkg),
    ("$VERSION", ret.version),
    ("$RELEASE", ret.release),
    ("$EPOCH", ret.epoch),
    ("$SHA256SUM", ret.sha256sum),
    ("\"", ""),
    ("'", "")
    )

    ret.sha256sum = ret.sha256sum.multiReplace(
    ("$NAME", ret.pkg),
    ("$VERSION", ret.version),
    ("$RELEASE", ret.release),
    ("$EPOCH", ret.epoch),
    ("$SHA256SUM", ret.sha256sum),
    ("\"", ""),
    ("'", "")
    )

    return ret
