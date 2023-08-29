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
    optdeps*: seq[string]
    replaces*: seq[string]
    noChkupd*: bool

proc parse_runfile*(path: string, removeLockfileWhenErr = true): runFile =
    ## Parse an runfile.

    var vars: seq[string]
    var ret: runFile

    try:
        for i in lines path&"/run":
            if i.split('=').len >= 3:
                vars = i.split('"')
                vars[0] = replace(vars[0], "=")
            else:
                vars = i.split('=')
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
                of "NO_CHKUPD":
                    ret.noChkupd = parseBool(vars[1].multiReplace(
                    ("\"", ""),
                    ("'", "")
                    ))
                of "EPOCH":
                    ret.epoch = vars[1].multiReplace(
                    ("\"", ""),
                    ("'", "")
                    )
                of "SHA256SUM":
                    ret.sha256sum = vars[1]
                of "CONFLICTS":
                    ret.conflicts = vars[1].multiReplace(
                    ("\"", ""),
                    ("'", "")
                    ).split(" ")
                of "DEPENDS":
                    ret.deps = vars[1].multiReplace(
                    ("\"", ""),
                    ("'", "")
                    ).split(" ")
                of "BUILD_DEPENDS":
                    ret.bdeps = vars[1].multiReplace(
                    ("\"", ""),
                    ("'", "")
                    ).split(" ")
                of "OPTDEPENDS":
                    ret.optdeps = vars[1].multiReplace(
                    ("\"", ""),
                    ("'", "")
                    ).split(" ;; ")
                of "REPLACES":
                    ret.replaces = vars[1].multiReplace(
                    ("\"", ""),
                    ("'", "")
                    ).split(" ")
            if "()" in vars[0]:
                break
    except CatchableError:
        err(path&" doesn't seem to have a runfile. possibly a broken package?", removeLockfileWhenErr)

    when declared(ret.epoch):
        ret.versionString = ret.version&"-"&ret.release&"-"&ret.epoch
    else:
        ret.versionString = ret.version&"-"&ret.release
        ret.epoch = "no"

    if not isEmptyOrWhitespace(ret.sources):
        ret.sources = splitWhitespace(ret.sources.multiReplace(
            ("$NAME", ret.pkg),
            ("$VERSION", ret.version),
            ("$RELEASE", ret.release),
            ("$EPOCH", ret.epoch),
            ("$SHA256SUM", ret.sha256sum),
            ("\"", ""),
            ("'", "")
            ))[0]

    if not isEmptyOrWhitespace(ret.sha256sum):
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
