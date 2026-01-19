import os
import strutils
import ../../common/logging
import ../modules/config
import ../modules/sqlite
import ../modules/overrides
import ../modules/downloader
import ../modules/dephandler

# base functions
#
# db.package.packageName.variable # eg. package.kpkg.version
# config.variable # eg. config.Repositories.repoLinks
# vars.variable # eg. internal.vars.envDir
# overrides.packageName.variable # eg. overrides.bash.cflags
# depends.packageName.build # eg. depends.bash.build (build dependencies)
# depends.packageName.install # eg. depends.bash.install (install dependencies)
#
# Can also get all variables
# `kpkg get config` # prints all config variables

proc get*(invocations: seq[string]) =
  ## Gets a kpkg value. See kpkg_get(5) for more information.
  if invocations.len < 1:
    error("No invocation provided. See kpkg_get(5) for more information.")
    quit(1)

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
                echo getPackageByValue(getPackage(invocSplit[2],
                        "/"), invocSplit[3])
              else:
                error("'"&invoc&"': invalid invocation")
                quit(1)
          of "file":
            case invocSplit.len:
              of 2:
                getFileByValueAll("/")
              of 3:
                echo getFileByValue(getFile(invocSplit[2], "/"))
              of 4:
                echo getFileByValue(getFile(invocSplit[2], "/"),
                        invocSplit[3])
              else:
                error("'"&invoc&"': invalid invocation")
                quit(1)
      of "config":
        case invocSplit.len:
          of 1:
            echo returnConfig()
          of 2:
            echo getConfigSection(invocSplit[1])
          of 3:
            echo getConfigValue(invocSplit[1], invocSplit[2])
          else:
            error("'"&invoc&"': invalid invocation")
            quit(1)
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
            echo getOverrideValue(invocSplit[1], invocSplit[2],
                    invocSplit[3])
          else:
            error("'"&invoc&"': invalid invocation")
            quit(1)
      of "depends":
        case invocSplit.len:
          of 3:
            let packageName = invocSplit[1]
            let depType = invocSplit[2]

            # Check if package exists in repos
            let repo = findPkgRepo(packageName)
            if repo == "":
              error("'"&packageName&"': package not found")
              quit(1)

            var deps: seq[string]
            try:
              case depType:
                of "build":
                  # Get build dependencies (both bdeps and deps)
                  # Set ignoreCircularDeps=true to silently handle circular dependencies
                  deps = dephandler(@[packageName],
                          isBuild = true, root = "/",
                          prevPkgName = packageName,
                          ignoreCircularDeps = true)
                of "install":
                  # Get install dependencies only
                  # Set ignoreCircularDeps=true to silently handle circular dependencies
                  deps = dephandler(@[packageName],
                          root = "/",
                          prevPkgName = packageName,
                          ignoreCircularDeps = true)
                else:
                  error("'"&depType&"': invalid dependency type. Use 'build' or 'install'")
                  quit(1)

              # Output the dependencies
              for dep in deps:
                echo dep
            except CatchableError:
              error("failed to resolve dependencies for '"&packageName&"'")
              quit(1)
          of 4:
            let packageName = invocSplit[1]
            let depType = invocSplit[2]
            let outputFormat = invocSplit[3]

            # Only support .graph output format
            if outputFormat != "graph":
              error("'"&outputFormat&"': invalid output format. Use 'graph'")
              quit(1)

            # Check if package exists in repos
            let repo = findPkgRepo(packageName)
            if repo == "":
              error("'"&packageName&"': package not found")
              quit(1)

            try:
              # Build the dependency graph
              let ctx = dependencyContext(
                  root: "/",
                  isBuild: (depType == "build"),
                  useBootstrap: false,
                  ignoreInit: false,
                  ignoreCircularDeps: true,
                  forceInstallAll: false,
                  init: ""
              )

              var graph: dependencyGraph
              case depType:
                of "build":
                  # Build graph with build dependencies
                  graph = buildDependencyGraph(@[packageName],
                          ctx, @["  "], false, false, packageName)
                of "install":
                  # Build graph with install dependencies only
                  graph = buildDependencyGraph(@[packageName],
                          ctx, @["  "], false, false, packageName)
                else:
                  error("'"&depType&"': invalid dependency type. Use 'build' or 'install'")
                  quit(1)

              # Generate and output Mermaid chart
              echo generateMermaidChart(graph, @[packageName])
            except CatchableError:
              error("failed to generate dependency graph for '"&packageName&"'")
              quit(1)
          else:
            error("'"&invoc&"': invalid invocation. Usage: depends.packageName.build[.graph] or depends.packageName.install[.graph]")
            quit(1)
      else:
        error("'"&invoc&"': invalid invocation. Available invocations: db, config, overrides, depends. See kpkg_get(5) for more information.")
        quit(1)

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
        error("'"&file&"': file does not exist.")
        quit(1)

    for line in lines fileToRead:

      # Check for comments and whitespace
      if line.startsWith("#") or isEmptyOrWhitespace(line):
        continue

      let lineSplit = line.split(" ")

      debug "lineSplit: '"&($lineSplit)&"'"

      try:
        case lineSplit[1]:
          of "=", "==":
            set(append = false, invocation = @[lineSplit[0],
                    lineSplit[2]])
          of "+=":
            set(append = true, invocation = @[lineSplit[0],
                    lineSplit[2]])
          else:
            error("'"&line&"': invalid invocation.")
            quit(1)
      except:
        when not defined(release):
          raise getCurrentException()
        else:
          error("'"&line&"': invalid invocation.")
          quit(1)

    return

  if invocation.len < 2:
    error("No invocation provided. See kpkg_set(5) for more information.")
    quit(1)

  let invocSplit = invocation[0].split(".")

  case invocSplit[0]:
    of "config":
      if invocSplit.len < 3:
        error("'"&invocation[0]&"': invalid invocation.")
        quit(1)

      if append:
        setConfigValue(invocSplit[1], invocSplit[2], getConfigValue(
                invocSplit[1], invocSplit[2])&" "&invocation[1])
      else:
        setConfigValue(invocSplit[1], invocSplit[2], invocation[1])

      echo getConfigValue(invocSplit[1], invocSplit[2])
    of "overrides":
      if invocSplit.len < 3:
        error("'"&invocation[0]&"': invalid invocation.")
        quit(1)

      if append:
        setOverrideValue(invocSplit[1], invocSplit[2], invocSplit[3],
                getOverrideValue(invocSplit[1], invocSplit[2],
                invocSplit[3])&" "&invocation[1])
      else:
        setOverrideValue(invocSplit[1], invocSplit[2], invocSplit[3],
                invocation[1])

      echo getOverrideValue(invocSplit[1], invocSplit[2], invocSplit[3])
