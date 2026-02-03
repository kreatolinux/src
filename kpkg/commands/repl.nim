import os
import strutils
import terminal
import tables
import ../../common/logging
import ../modules/config
import ../modules/sqlite
import ../modules/overrides
import ../modules/downloader
import ../modules/dephandler
import ../modules/run3/run3
import rdstdin

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

proc get(args: seq[string]) =
  ## Gets a kpkg value. See kpkg_get(5) for more information.
  if args.len < 1:
    echo "Usage: get [invocation]"
    return

  for invoc in args:
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
      of "depends":
        case invocSplit.len:
          of 3:
            let packageName = invocSplit[1]
            let depType = invocSplit[2]

            # Check if package exists in repos
            let repo = findPkgRepo(packageName)
            if repo == "":
              error("'"&packageName&"': package not found")
              return

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
                  return

              # Output the dependencies
              for dep in deps:
                echo dep
            except CatchableError:
              error("failed to resolve dependencies for '"&packageName&"'")
          of 4:
            let packageName = invocSplit[1]
            let depType = invocSplit[2]
            let outputFormat = invocSplit[3]

            # Only support .graph output format
            if outputFormat != "graph":
              error("'"&outputFormat&"': invalid output format. Use 'graph'")
              return

            # Check if package exists in repos
            let repo = findPkgRepo(packageName)
            if repo == "":
              error("'"&packageName&"': package not found")
              return

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
                  return

              # Generate and output Mermaid chart
              echo generateMermaidChart(graph, @[packageName])
            except CatchableError:
              error("failed to generate dependency graph for '"&packageName&"'")
          else:
            error("'"&invoc&"': invalid invocation. Usage: depends.packageName.build[.graph] or depends.packageName.install[.graph]")
      else:
        error("'"&invoc&"': invalid invocation. Available invocations: db, config, overrides, depends. See kpkg_get(5) for more information.")

proc set(args: seq[string]) =
  ## Sets a kpkg value. See kpkg_set(5) for more information.
  if args.len < 2:
    echo "Usage: set [invocation] [value]"
    return

  try:
    let key = args[0]
    let val = args[1..^1].join(" ")
    let invocSplit = key.split(".")

    case invocSplit[0]:
      of "config":
        if invocSplit.len < 3:
          error("'"&key&"': invalid invocation.")
          return
        setConfigValue(invocSplit[1], invocSplit[2], val)
        echo getConfigValue(invocSplit[1], invocSplit[2])
      of "overrides":
        if invocSplit.len < 4:
          error("'"&key&"': invalid invocation.")
          return
        setOverrideValue(invocSplit[1], invocSplit[2], invocSplit[3], val)
        echo getOverrideValue(invocSplit[1], invocSplit[2], invocSplit[3])
  except CatchableError as e:
    error(e.msg)

proc handleRun3Statement(ctx: ExecutionContext, line: string) =
  ## Parses and executes a run3 statement or function definition.
  try:
    let tokens = tokenize(line)
    var parser = initParser(tokens)

    # Check if this is a function definition
    let firstTok = parser.peek()
    if firstTok.kind == tkFunc or (firstTok.kind == tkIdentifier and
        parser.peek(1).kind == tkLBrace):
      let isCustom = firstTok.kind == tkFunc
      let funcNode = parser.parseFunction(isCustom)

      # Load into context
      if funcNode.kind == nkFunction:
        ctx.customFuncs[funcNode.funcName] = funcNode.funcBody
        debug "Defined regular function: " & funcNode.funcName
      elif funcNode.kind == nkCustomFunc:
        ctx.customFuncs[funcNode.customFuncName] = funcNode.customFuncBody
        debug "Defined custom function: " & funcNode.customFuncName
    else:
      # Regular statement
      let node = parser.parseStatement()
      let res = executor.executeNode(ctx, node)
      if res != 0:
        debug "Command returned non-zero exit code: " & $res
  except ParseError as e:
    error("Parse error at line " & $e.line & ", col " & $e.col & ": " & e.msg)
  except ExecutionError as e:
    error("Execution error at line " & $e.line & ": " & e.msg)
  except CatchableError as e:
    error("Error: " & e.msg)

proc dispatchCommand(ctx: ExecutionContext, input: string) =
  ## Dispatches a command (get, set, or run3 statement).
  let inputTrimmed = input.strip()
  if inputTrimmed == "": return

  let parts = inputTrimmed.split(" ", 1)
  let cmd = parts[0]
  let args = if parts.len > 1: parts[1].split(" ") else: @[]

  case cmd
  of "get":
    get(args)
  of "set":
    set(args)
  else:
    handleRun3Statement(ctx, inputTrimmed)

proc repl*(args: seq[string] = @[]) =
  ## Starts the kpkg REPL with history support.
  let ctx = initExecutionContext()
  let historyPath = getCacheDir() / "kpkg"
  let historyFile = historyPath / "history"

  # Ensure config dir exists
  try:
    if not dirExists(historyPath):
      createDir(historyPath)
  except:
    discard

  if args.len > 0:
    # Process commands from arguments
    dispatchCommand(ctx, args.join(" "))
    return

  echo "kpkg REPL (run3)"
  echo "Type 'exit' or 'quit' to leave."

  var buffer = ""
  var braceCount = 0

  while true:
    var line: string
    let prompt = if braceCount > 0: "      " else: "kpkg> "
    let ok = readLineFromStdin(prompt, line)

    if not ok: # EOF
      break

    let trimmed = line.strip()
    if trimmed == "" and buffer == "":
      continue

    if (trimmed == "exit" or trimmed == "quit") and buffer == "":
      break

    if buffer != "":
      buffer.add("\n")
    buffer.add(line)

    # Simple brace counting to handle multi-line blocks
    for c in line:
      if c == '{': braceCount += 1
      elif c == '}': braceCount -= 1

    if braceCount > 0:
      continue

    let fullInput = buffer.strip()
    buffer = ""
    braceCount = 0 # Reset just in case it went negative

    if fullInput == "":
      continue

    # Save to history file (skip exit commands and very short single-word commands that might be typos)
    if fullInput notin ["exit", "quit", "help", "history", "clear"]:
      try:
        let f = open(historyFile, fmAppend)
        f.writeLine(fullInput)
        f.close()
      except:
        discard

    if fullInput == "history":
      try:
        echo readFile(historyFile)
      except:
        error("Could not read history file")
      continue

    if fullInput == "clear":
      eraseScreen()
      setCursorPos(0, 0)
      flushFile(stdout)
      continue

    # Dispatch commands
    dispatchCommand(ctx, fullInput)
