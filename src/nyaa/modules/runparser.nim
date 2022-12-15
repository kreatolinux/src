var vars: seq[string]
var pkg: string
var sources: string
var version: string
var release: string
var sha256sum: string
var epoch: string

proc parse_runfile(path: string) =
    ## Parse an runfile.

    for i in lines path&"/run":
        vars = i.split("=")
        case vars[0]:
            of "NAME":
                pkg = vars[1].replace("\"", "").replace("'", "")
            of "SOURCES":
                sources = vars[1].replace("\"", "").replace("'", "")
            of "VERSION":
                version = vars[1].replace("\"", "").replace("'", "")
            of "RELEASE":
                release = vars[1].replace("\"", "").replace("'", "")
            of "EPOCH":
                epoch = vars[1].replace("\"", "").replace("'", "")
            of "SHA256SUM":
                sha256sum = vars[1].replace("\"", "").replace("'", "")

        if "()" in vars[0]:
            break
