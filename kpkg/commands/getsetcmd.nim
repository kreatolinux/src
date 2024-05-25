import os
import strutils
import ../modules/logger
import ../modules/config
import ../modules/sqlite
import ../modules/overrides
import ../modules/downloader

# base functions
#
# db.package.packageName.variable # eg. package.kpkg.version
# config.variable # eg. config.Repositories.repoLinks
# vars.variable # eg. internal.vars.envDir
# overrides.packageName.variable # eg. overrides.bash.cflags
#
# Can also get all variables
# `kpkg get config` # prints all config variables

proc get*(invocations: seq[string]) =
    ## Gets a kpkg value. See kpkg_get(5) for more information.
    if invocations.len < 1:
        err("No invocation provided. See kpkg_get(5) for more information.", false)
        return

    for invoc in invocations: 
        let invocSplit = invoc.split(".")
        case invocSplit[0]:
          of "db":
            if invocSplit.len < 2:
                info("available invocations: db.package, db.file")
                continue

            case invocSplit[1]:
                of "package":
                    case invocSplit.len:
                        of 2:
                            getPackageByValueAll("/")
                        of 3:
                            echo getPackageByValue(getPackage(invocSplit[2], "/"))
                        of 4:
                            echo getPackageByValue(getPackage(invocSplit[2], "/"), invocSplit[3])
                        else:
                            err("'"&invoc&"': invalid invocation", false)
                            continue
                of "file":
                    case invocSplit.len:
                        of 2:
                            getFileByValueAll("/")
                        of 3:
                            echo getFileByValue(getFile(invocSplit[2], "/"))
                        of 4:
                            echo getFileByValue(getFile(invocSplit[2], "/"), invocSplit[3])
                        else:
                            err("'"&invoc&"': invalid invocation", false)
                            continue
          of "config":
            case invocSplit.len:
                of 1:
                    echo returnConfig()
                of 2:
                    echo getConfigSection(invocSplit[1])
                of 3:
                    echo getConfigValue(invocSplit[1], invocSplit[2])
                else:
                    err("'"&invoc&"': invalid invocation", false)
                    continue
          of "overrides":
            case invocSplit.len:
                of 1:
                    for override in allOverrides():
                        echo readFile(override)
                of 2:
                    echo returnOverride(invocSplit[1])
                of 3:
                    echo getOverrideSection(invocSplit[1], invocSplit[2])
                of 4:
                    echo getOverrideValue(invocSplit[1], invocSplit[2], invocSplit[3])
                else:
                    err("'"&invoc&"': invalid invocation", false)
                    continue
          else:
            err("'"&invoc&"': invalid invocation. Available invocations: db, config, overrides. See kpkg_get(5) for more information.", false)
            continue

proc set*(file = "", append = false, invocation: seq[string]) =
    ## Sets a kpkg value. See kpkg_set(5) for more information.

    if not isEmptyOrWhitespace(file):
        var fileToRead = file
        if file.startsWith("https://") or file.startsWith("http://"):
            createDir("/tmp/kpkg")
            download(file, "/tmp/kpkg/"&lastPathPart(file))
            fileToRead = lastPathPart(file)
        else:
            if not fileExists(file):
                err("'"&file&"': file does not exist.", false)
       
        for line in lines fileToRead:

            # Check for comments and whitespace
            if line.startsWith("#") or isEmptyOrWhitespace(line):
                continue

            let lineSplit = line.split(" ")
            
            debug "lineSplit: '"&($lineSplit)&"'"

            try:
                case lineSplit[1]:
                    of "=", "==":
                        set(append = false, invocation = @[lineSplit[0], lineSplit[2]])
                    of "+=":
                        set(append = true, invocation = @[lineSplit[0], lineSplit[2]])
                    else:
                        err("'"&line&"': invalid invocation.", false)
                        continue
            except:
                when not defined(release):
                    raise getCurrentException()
                else:
                    err("'"&line&"': invalid invocation.", false)
                    continue

        return

    if invocation.len < 2:
        err("No invocation provided. See kpkg_set(5) for more information.", false)
        return

    let invocSplit = invocation[0].split(".")

    case invocSplit[0]:
        of "config":
            if invocSplit.len < 3:
                err("'"&invocation[0]&"': invalid invocation.", false)

            if append:
                setConfigValue(invocSplit[1], invocSplit[2], getConfigValue(invocSplit[1], invocSplit[2])&" "&invocation[1])
            else:
                setConfigValue(invocSplit[1], invocSplit[2], invocation[1])
            
            echo getConfigValue(invocSplit[1], invocSplit[2])
        of "overrides":
            if invocSplit.len < 3:
                err("'"&invocation[0]&"': invalid invocation.", false)

            if append:
                setOverrideValue(invocSplit[1], invocSplit[2], invocSplit[3], getOverrideValue(invocSplit[1], invocSplit[2], invocSplit[3])&" "&invocation[1])
            else:
                setOverrideValue(invocSplit[1], invocSplit[2], invocSplit[3], invocation[1])

            echo getOverrideValue(invocSplit[1], invocSplit[2], invocSplit[3])
