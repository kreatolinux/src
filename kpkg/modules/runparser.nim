import os
import logger
import parsecfg
import strutils
import tables


# Function name validation
proc isValidFunctionName(name: string): bool =
    if name.len == 0: return false
    let first = name[0]
    if not (first.isAlphaAscii or first == '_'): return false
    for c in name[1..^1]:
        if not (c.isAlphaNumeric or c == '_'): return false
    return true

type runFile* = object
    pkg*: string
    sources*: string
    version*: string
    release*: string
    extract*: bool = true
    sha256sum*: string
    sha512sum*: string
    b2sum*: string
    epoch*: string
    desc*: string
    versionString*: string
    conflicts*: seq[string]
    deps*: seq[string]
    bdeps*: seq[string]
    bsdeps*: seq[string]
    backup*: seq[string]
    optdeps*: seq[string]
    replaces*: seq[string]
    noChkupd*: bool
    isGroup*: bool
    isParsed*: bool
    isSemver*: bool = false
    functions*: seq[tuple[name: string, body: string]]

proc parseRunfile*(path: string, removeLockfileWhenErr = true): runFile =
    ## Parse a runfile.

    var vars: seq[string]
    var ret: runFile
    ret.functions = @[]
    let package = lastPathPart(path)
    var extractisRead = false
    var override: Config
    
    # Function parsing state
    var currentFunction = ""
    var braceCount = 0
    var functionBody: seq[string]
    
    if fileExists("/etc/kpkg/override/"&package&".conf"):
        override = loadConfig("/etc/kpkg/override/"&package&".conf")
    else:
        override = newConfig() # So we don't get storage access errors

    try:
        for i in lines path&"/run":
            if i.split('=').len >= 3:
                vars = i.split('"')
                vars[0] = replace(vars[0], "=")
            else:
                vars = i.split('=')
            case vars[0].toLower:
                of "name":
                    ret.pkg = override.getSectionValue("runFile", "name", vars[1].multiReplace(
                    ("\"", ""),
                    ("'", "")
                    ).strip())
                of "description":
                    ret.desc = override.getSectionValue("runFile", "description", vars[1].multiReplace(
                    ("\"", ""),
                    ("'", "")
                    ).strip())
                of "sources":
                    ret.sources = override.getSectionValue("runFile", "sources", vars[1].strip())
                of "version":
                    ret.version = override.getSectionValue("runFile", "version", vars[1].multiReplace(
                    ("\"", ""),
                    ("'", "")
                    ).strip())
                of "release":
                    ret.release = override.getSectionValue("runFile", "release", vars[1].multiReplace(
                    ("\"", ""),
                    ("'", "")
                    ).strip())
                of "no_chkupd", "nochkupd", "no-chkupd":
                    ret.noChkupd = parseBool(override.getSectionValue("runFile", "noChkupd", vars[1].multiReplace(
                    ("\"", ""),
                    ("'", "")
                    ).strip()))
                of "is_semver", "issemver", "is-semver":
                    ret.noChkupd = parseBool(override.getSectionValue("runFile", "isSemver", vars[1].multiReplace(
                    ("\"", ""),
                    ("'", "")
                    ).strip()))
                of "epoch":
                    ret.epoch = override.getSectionValue("runFile", "epoch", vars[1].multiReplace(
                    ("\"", ""),
                    ("'", "")
                    ).strip())
                of "backup":
                    ret.backup = override.getSectionValue("runFile", "backup", vars[1].multiReplace(
                    ("\"", ""),
                    ("'", "")
                    ).strip()).split(" ")
                of "sha256sum":
                    ret.sha256sum = override.getSectionValue("runFile", "sha256sum", vars[1].strip())
                of "sha512sum":
                    ret.sha512sum = override.getSectionValue("runFile", "sha512sum", vars[1].strip())
                of "b2sum":
                    ret.b2sum = override.getSectionValue("runFile", "b2sum", vars[1].strip())
                of "conflicts":
                    ret.conflicts = override.getSectionValue("runFile", "conflicts", vars[1].multiReplace(
                    ("\"", ""),
                    ("'", "")
                    ).strip()).split(" ")
                of "depends":
                    ret.deps = override.getSectionValue("runFile", "depends", vars[1].multiReplace(
                    ("\"", ""),
                    ("'", "")
                    ).strip()).split(" ")
                of "build_depends", "builddepends", "build-depends":
                    ret.bdeps = override.getSectionValue("runFile", "buildDepends", vars[1].multiReplace(
                    ("\"", ""),
                    ("'", "")
                    ).strip()).split(" ")
                of "bootstrap_depends", "bootstrapdepends", "bootstrap-depends":
                    ret.bsdeps = override.getSectionValue("runFile", "bootstrapDepends", vars[1].multiReplace(
                    ("\"", ""),
                    ("'", "")
                    ).strip()).split(" ")
                of "optdepends", "opt-depends", "opt_depends":
                    ret.optdeps = override.getSectionValue("runFile", "optDepends", vars[1].multiReplace(
                    ("\"", ""),
                    ("'", "")
                    ).strip()).split(" ;; ")
                of "is_group", "is-group", "isgroup":
                    ret.isGroup = parseBool(override.getSectionValue("runFile", "isGroup", vars[1].multiReplace(
                    ("\"", ""),
                    ("'", "")
                    ).strip()))
                of "extract":
                    extractisRead = true
                    ret.extract = parseBool(override.getSectionValue("runFile", "extract", vars[1].multiReplace(
                    ("\"", ""),
                    ("'", "")
                    ).strip()))
                of "replaces":
                    ret.replaces = override.getSectionValue("runFile", "replaces", vars[1].multiReplace(
                    ("\"", ""),
                    ("'", "")
                    ).strip()).split(" ")
            
            # Handle function definitions and bodies
            if currentFunction == "":
                # Check for all function definition styles
                var trimmed = i.strip()
                # Handle all possible forms: func(){, func() {, func {, func{
                if '{' in trimmed:
                    var funcName = trimmed
                    # Remove everything from { onwards
                    funcName = funcName[0..funcName.find('{')-1].strip()
                    # Remove parentheses if they exist
                    if funcName.endsWith("()"):
                        funcName = funcName[0..^3].strip()
                    
                    if isValidFunctionName(funcName):
                        currentFunction = funcName
                        braceCount = 1
                        functionBody = @[i]
                        #debug("FUNCPARSE: Found function " & currentFunction & " at line: " & i)
                        continue
                    else:
                        #debug("FUNCPARSE: Invalid function name: " & funcName)
                        continue

            if currentFunction != "":
                let initialBraces = braceCount
                braceCount += i.count('{')
                braceCount -= i.count('}')
                
                var braceEvents: seq[string] = @[]
                if i.count('{') > 0:
                    braceEvents.add("+{" & $i.count('{') & "}")
                if i.count('}') > 0:
                    braceEvents.add("-}" & $i.count('}') & "}")
                
                #debug("FUNCPARSE: " & currentFunction &
                #      " | Braces: " & $initialBraces & " → " & $braceCount &
                #      " | Changes: " & braceEvents.join(", ") &
                #      " | Line: " & i)
                
                functionBody.add(i)
                
                if braceCount == 0:
                    if functionBody.len > 0:
                        ret.functions.add((name: currentFunction, body: functionBody.join("\n")))
                        #debug("FUNCPARSE: Completed function " & currentFunction &
                        #      " | Body lines: " & $functionBody.len)
                    #else:
                        #debug("FUNCPARSE: Empty function body for " & currentFunction)
                    currentFunction = ""
                    functionBody = @[]
                continue

            # There gotta be a cleaner way to do this, hmu if you know one -kreato
            let p = replace(package, '-', '_')

            if vars[0].toLower == "depends_"&p&"+" or vars[0].toLower ==
                    "depends-"&p&"+" or vars[0].toLower == "depends"&p&"+":
                ret.deps = ret.deps&vars[1].multiReplace(
                ("\"", ""),
                ("'", "")
                ).split(" ")
            elif vars[0].toLower == "depends_"&p&"-" or vars[0].toLower ==
                    "depends-"&p&"-" or vars[0].toLower == "depends"&p&"-":
                for i in vars[1].multiReplace(
                ("\"", ""),
                ("'", "")
                ).split(" "):
                    if ret.deps.find(i) != -1:
                        ret.deps.delete(ret.deps.find(i))
            elif vars[0].toLower == "depends_"&p or vars[0].toLower ==
                    "depends-"&p or vars[0].toLower == "depends"&p:
                ret.deps = vars[1].multiReplace(
                ("\"", ""),
                ("'", "")
                ).split(" ")
            
            if vars[0].toLower == "bootstrap_depends_"&p&"+" or vars[0].toLower ==
                    "bootstrap-depends-"&p&"+" or vars[0].toLower == "bootstrapdepends"&p&"+":
                ret.bsdeps = ret.bsdeps&vars[1].multiReplace(
                ("\"", ""),
                ("'", "")
                ).split(" ")
            elif vars[0].toLower == "bootstrap_depends_"&p&"-" or vars[0].toLower ==
                    "bootstrap-depends-"&p&"-" or vars[0].toLower == "bootstrapdepends"&p&"-":
                for i in vars[1].multiReplace(
                ("\"", ""),
                ("'", "")
                ).split(" "):
                    if ret.bsdeps.find(i) != -1:
                        ret.bsdeps.delete(ret.bsdeps.find(i))
            elif vars[0].toLower == "bootstrap_depends_"&p or vars[0].toLower ==
                    "bootstrap-depends-"&p or vars[0].toLower == "bootstrapdepends"&p:
                ret.bsdeps = vars[1].multiReplace(
                ("\"", ""),
                ("'", "")
                ).split(" ")

    except CatchableError:
        when defined(release):
            err(path&" doesn't seem to have a runfile. possibly a broken package?", removeLockfileWhenErr)
        else:
            debug(path&" doesn't seem to have a runfile. possibly a broken package?")
            raise getCurrentException()

    when declared(ret.epoch):
        ret.versionString = ret.version&"-"&ret.release&"-"&ret.epoch
    else:
        ret.versionString = ret.version&"-"&ret.release
        ret.epoch = "no"

        var replaceWith = @[
            ("$NAME", ret.pkg),
            ("$Name", ret.pkg),
            ("$name", ret.pkg),
            ("$VERSION", ret.version),
            ("$Version", ret.version),
            ("$version", ret.version),
            ("$RELEASE", ret.release),
            ("$release", ret.release),
            ("$Release", ret.release),
            ("$EPOCH", ret.epoch),
            ("$epoch", ret.epoch),
            ("$Epoch", ret.epoch),
            ("$SHA256SUM", ret.sha256sum),
            ("$sha256sum", ret.sha256sum),
            ("$Sha256sum", ret.sha256sum),
            ("$SHA512SUM", ret.sha512sum),
            ("$sha512sum", ret.sha512sum),
            ("$Sha512sum", ret.sha512sum),
            ("$b2sum", ret.b2sum),
            ("$B2sum", ret.b2sum),
            ("$B2SUM", ret.b2sum),
            ("\"", ""),
            ("'", "")
            ]

    if not isEmptyOrWhitespace(ret.sha256sum):
        ret.sha256sum = ret.sha256sum.multiReplace(replaceWith)
   
    if not extractisRead:
        ret.extract = true # default value

    if not isEmptyOrWhitespace(ret.sources):
        ret.sources = ret.sources.multiReplace(replaceWith)

    if not isEmptyOrWhitespace(ret.sha512sum):
        ret.sha512sum = ret.sha512sum.multiReplace(replaceWith)
    
    if not isEmptyOrWhitespace(ret.b2sum):
        ret.b2sum = ret.b2sum.multiReplace(replaceWith)

    # Replace variables in function bodies
    for i in 0..<ret.functions.len:
        if not isEmptyOrWhitespace(ret.functions[i].body):
            ret.functions[i].body = ret.functions[i].body.multiReplace(replaceWith)

    ret.isParsed = true

    # Log final function parsing statistics
    var validFuncs = 0
    var totalChars = 0
    for fn in ret.functions:
        if not isEmptyOrWhitespace(fn.body):
            validFuncs += 1
            totalChars += fn.body.len
    
    #debug("FUNCPARSE: Final stats - Valid functions: " & $validFuncs &
    #      " | Total characters: " & $totalChars &
    #     " | Average chars per function: " & 
    #      (if validFuncs > 0: $(totalChars div validFuncs) else: "0"))

    return ret
