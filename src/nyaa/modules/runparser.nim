type runFile = object
    pkg: string
    sources: string
    version: string
    release: string
    sha256sum: string
    epoch: string
    versionString: string

proc parse_runfile(path: string): runFile =
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
                    ret.sources = vars[1].multiReplace(
                    ("\"", ""),
                    ("'", "")
                    )
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
                of "EPOCH":
                    ret.epoch = vars[1].multiReplace(
                    ("\"", ""),
                    ("'", "")
                    )
                of "SHA256SUM":
                    ret.sha256sum = vars[1].multiReplace(
                    ("\"", ""),
                    ("'", "")
                    )
                else:
                    break
    except:
        err(path&" doesn't seem to have a runfile. possibly a broken package?")

    when declared(ret.epoch):
        ret.versionString = ret.version&"-"&ret.release&"-"&ret.epoch
    else:
        ret.versionString = ret.version&"-"&ret.release
        ret.epoch = "no"

    return ret
