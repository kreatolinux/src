import os
import logger
import strutils

type runFile* = object
    pkg*: string
    sources*: string
    version*: string
    release*: string
    sha256sum*: string
    epoch*: string
    desc*: string
    versionString*: string
    conflicts*: seq[string]
    deps*: seq[string]
    bdeps*: seq[string]
    optdeps*: seq[string]
    replaces*: seq[string]
    noChkupd*: bool
    isGroup*: bool
    isParsed*: bool

proc parseRunfile*(path: string, removeLockfileWhenErr = true): runFile =
    ## Parse a runfile.

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
                of "DESCRIPTION":
                    ret.desc = vars[1].multiReplace(
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
                of "IS_GROUP":
                    ret.isGroup = parseBool(vars[1].multiReplace(
                    ("\"", ""),
                    ("'", "")
                    ))
                of "REPLACES":
                    ret.replaces = vars[1].multiReplace(
                    ("\"", ""),
                    ("'", "")
                    ).split(" ")
            if "()" in vars[0]:
                break

            if vars[0].toLower == "depends_"&replace(lastPathPart(path), '-', '_')&"+":
                ret.deps = ret.deps&vars[1].multiReplace(
                ("\"", ""),
                ("'", "")
                ).split(" ")
            elif vars[0].toLower == "depends_"&replace(lastPathPart(path), '-', '_')&"-":
                for i in vars[1].multiReplace(
                ("\"", ""),
                ("'", "")
                ).split(" "):
                    if ret.deps.find(i) != -1:
                        ret.deps.delete(ret.deps.find(i))
            elif vars[0].toLower == "depends_"&replace(lastPathPart(path), '-', '_'):
                ret.deps = vars[1].multiReplace(
                ("\"", ""),
                ("'", "")
                ).split(" ")

    except CatchableError:
        err(path&" doesn't seem to have a runfile. possibly a broken package?", removeLockfileWhenErr)

    when declared(ret.epoch):
        ret.versionString = ret.version&"-"&ret.release&"-"&ret.epoch
    else:
        ret.versionString = ret.version&"-"&ret.release
        ret.epoch = "no"

    if not isEmptyOrWhitespace(ret.sources):
        ret.sources = ret.sources.multiReplace(
            ("$NAME", ret.pkg),
            ("$VERSION", ret.version),
            ("$RELEASE", ret.release),
            ("$EPOCH", ret.epoch),
            ("$SHA256SUM", ret.sha256sum),
            ("\"", ""),
            ("'", "")
            )

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

    ret.isParsed = true

    return ret
