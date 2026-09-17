## Convert command for run3tools
## Converts runfiles between format versions (e.g., Run2 -> Run3)

import os
import strutils
import sequtils
import tables
import terminal

type
  Run2Function = object
    ## A function definition in Run2 format
    name: string
    body: seq[string]

  Run2File = object
    ## Parsed Run2 file structure
    pkg: string
    version: string
    release: string
    epoch: string
    desc: string
    sources: seq[string]
    sha256sum: seq[string]
    sha512sum: seq[string]
    b2sum: seq[string]
    depends: seq[string]
    buildDepends: seq[string]
    bootstrapDepends: seq[string]
    optDepends: seq[string]
    conflicts: seq[string]
    replaces: seq[string]
    backup: seq[string]
    extract: bool
    noChkupd: bool
    isGroup: bool
    extraDepends: Table[string, seq[string]]
    functions: seq[Run2Function]

# =============================================================================
# Run2 Parser
# =============================================================================

proc isValidFunctionName(name: string): bool =
  ## Check if a string is a valid function name
  if name.len == 0: return false
  let first = name[0]
  if not (first.isAlphaAscii or first == '_'): return false
  for c in name[1..^1]:
    if not (c.isAlphaNumeric or c == '_'): return false
  return true

proc parseRun2(path: string): Run2File =
  ## Parse a Run2 format file
  var ret: Run2File
  ret.extract = true # default
  ret.extraDepends = initTable[string, seq[string]]()

  var currentFunction = ""
  var braceCount = 0
  var functionBody: seq[string] = @[]
  var bootstrapDependsExplicitlySet = false

  if not fileExists(path):
    raise newException(IOError, "File not found: " & path)

  for line in lines(path):
    let stripped = line.strip()
    if stripped.len == 0 or stripped.startsWith("#"):
      if currentFunction != "":
        functionBody.add(line)
      continue

    # Function parsing
    if currentFunction != "":
      braceCount += line.count('{')
      braceCount -= line.count('}')

      # Check if function ends
      if braceCount <= 0:
        functionBody.add(line)

        # Remove the last line if it's just '}'
        var finalBody = functionBody
        if finalBody[^1].strip() == "}":
          discard finalBody.pop()

        ret.functions.add(Run2Function(name: currentFunction, body: finalBody))
        currentFunction = ""
        functionBody = @[]
      else:
        functionBody.add(line)
      continue

    # Check for function start
    if '{' in stripped and not stripped.startsWith("if") and
        not stripped.startsWith("for") and not stripped.startsWith("else") and
        not stripped.startsWith("while") and not stripped.startsWith("case"):
      if "(" in stripped and ")" in stripped:
        var namePart = stripped.split('(')[0].strip()
        if isValidFunctionName(namePart):
          currentFunction = namePart
          braceCount = line.count('{') - line.count('}')
          continue

    # Variable parsing
    if '=' in stripped:
      let parts = stripped.split('=', 1)
      let key = parts[0].strip()
      var val = parts[1].strip()

      # Remove quotes
      if val.startsWith("\"") and val.endsWith("\""):
        val = val[1..^2]
      elif val.startsWith("'") and val.endsWith("'"):
        val = val[1..^2]

      # Handle += and -=
      var cleanKey = key
      var op = "="
      if key.endsWith("+"):
        cleanKey = key[0..^2]
        op = "+="
      elif key.endsWith("-"):
        cleanKey = key[0..^2]
        op = "-="

      case cleanKey.toUpperAscii()
      of "NAME": ret.pkg = val
      of "VERSION": ret.version = val
      of "RELEASE": ret.release = val
      of "EPOCH": ret.epoch = val
      of "DESCRIPTION": ret.desc = val
      of "SOURCES":
        let semiParts = val.split(';')
        for part in semiParts:
          let s = part.strip()
          if s.len > 0:
            let spaceParts = s.split(' ')
            for sp in spaceParts:
              if sp.strip().len > 0:
                ret.sources.add(sp.strip())
      of "SHA256SUM": ret.sha256sum = val.split(' ').filterIt(it.len > 0)
      of "SHA512SUM": ret.sha512sum = val.split(' ').filterIt(it.len > 0)
      of "B2SUM": ret.b2sum = val.split(' ').filterIt(it.len > 0)
      of "DEPENDS":
        let items = val.split(' ').filterIt(it.len > 0)
        if op == "+=": ret.depends.add(items)
        elif op == "-=": ret.depends.keepItIf(it notin items)
        else: ret.depends = items
      of "BUILD_DEPENDS":
        let items = val.split(' ').filterIt(it.len > 0)
        if op == "+=": ret.buildDepends.add(items)
        elif op == "-=": ret.buildDepends.keepItIf(it notin items)
        else: ret.buildDepends = items
      of "BOOTSTRAP_DEPENDS":
        let items = val.split(' ').filterIt(it.len > 0)
        if not bootstrapDependsExplicitlySet and ret.bootstrapDepends.len ==
            0 and op != "=":
          ret.bootstrapDepends = ret.buildDepends
          bootstrapDependsExplicitlySet = true

        if op == "+=": ret.bootstrapDepends.add(items)
        elif op == "-=": ret.bootstrapDepends.keepItIf(it notin items)
        else:
          ret.bootstrapDepends = items
          bootstrapDependsExplicitlySet = true
      of "OPTDEPENDS":
        let items = val.split(" ;; ").filterIt(it.len > 0)
        ret.optDepends.add(items)
      of "CONFLICTS": ret.conflicts = val.split(' ').filterIt(it.len > 0)
      of "REPLACES": ret.replaces = val.split(' ').filterIt(it.len > 0)
      of "BACKUP": ret.backup = val.split(' ').filterIt(it.len > 0)
      of "EXTRACT":
        try: ret.extract = parseBool(val)
        except: discard
      of "NO_CHKUPD":
        try: ret.noChkupd = parseBool(val)
        except: discard
      of "IS_GROUP":
        try: ret.isGroup = parseBool(val)
        except: discard
      else:
        let upperKey = cleanKey.toUpperAscii()
        if upperKey.startsWith("DEPENDS_"):
          let pkg = cleanKey[8..^1].toLowerAscii()
          let items = val.split(' ').filterIt(it.len > 0)
          if not ret.extraDepends.hasKey(pkg):
            ret.extraDepends[pkg] = @[]

          if op == "+=": ret.extraDepends[pkg].add(items)
          elif op == "-=": ret.extraDepends[pkg].keepItIf(it notin items)
          else: ret.extraDepends[pkg] = items

  return ret

# =============================================================================
# Conversion Helpers
# =============================================================================

proc checkHeredocStart(line: string): (bool, string) =
  ## Check if a line starts a heredoc, returns (isHeredoc, delimiter)
  let idx = line.find("<<")
  if idx == -1: return (false, "")

  var rest = line[idx+2..^1].strip()
  if rest.startsWith("-"): rest = rest[1..^1].strip()

  # Extract delimiter (handle quotes)
  var delim = rest.split(' ')[0]
  if delim.startsWith("\"") and delim.endsWith("\""):
    delim = delim[1..^2]
  elif delim.startsWith("'") and delim.endsWith("'"):
    delim = delim[1..^2]

  return (true, delim)

proc checkRedirection(line: string): (string, string, string) =
  ## Check for > or >> redirection
  ## Returns (command, filename, operator)
  if ">>" in line:
    let parts = line.split(">>", 1)
    return (parts[0].strip(), parts[1].strip(), "append")
  elif ">" in line:
    let parts = line.split(">", 1)
    return (parts[0].strip(), parts[1].strip(), "write")
  return (line, "", "")

proc escapeStringValue(s: string): string =
  ## Escape special characters in a string for run3 output
  result = ""
  for c in s:
    case c
    of '\n': result.add("\\n")
    of '\t': result.add("\\t")
    of '\r': result.add("\\r")
    of '\\': result.add("\\\\")
    of '"': result.add("\\\"")
    else: result.add(c)

proc convertFunctionBody(body: seq[string]): seq[string] =
  ## Convert Run2 function body to Run3 statements
  var res: seq[string] = @[]

  # Pass 1: Handle line continuations
  var joinedBody: seq[string] = @[]
  var currentLine = ""
  for line in body:
    var l = line
    # If we have a pending line, join it
    if currentLine.len > 0:
      l = currentLine & " " & l.strip()
      currentLine = ""

    if l.endsWith("\\"):
      currentLine = l[0..^2] # remove backslash
    else:
      joinedBody.add(l)
  if currentLine.len > 0:
    joinedBody.add(currentLine)

  # Pass 2: Process commands
  var i = 0
  while i < joinedBody.len:
    let line = joinedBody[i]
    let l = line.strip()

    if l.len == 0:
      res.add("")
      inc i
      continue
    if l.startsWith("#"):
      res.add("  " & l)
      inc i
      continue

    # Heredoc handling
    let (isHeredoc, delim) = checkHeredocStart(l)
    if isHeredoc:
      # Check redirection in the command part
      let (cmd, file, op) = checkRedirection(l)

      var heredocContent = ""
      inc i
      while i < joinedBody.len:
        let hLine = joinedBody[i]
        if hLine.strip() == delim:
          inc i
          break
        heredocContent.add(hLine & "\n")
        inc i

      if op == "write":
        res.add("  write \"" & file.replace("\"", "") & "\" \"\"\"\n" &
            heredocContent & "\"\"\"")
      elif op == "append":
        res.add("  append \"" & file.replace("\"", "") & "\" \"\"\"\n" &
            heredocContent & "\"\"\"")
      else:
        var fullScript = l & "\n" & heredocContent & delim
        res.add("  exec \"\"\"\n" & fullScript & "\n\"\"\"")
      continue

    # Regular commands
    if l.startsWith("cd "):
      let path = l[3..^1].strip()
      res.add("  cd \"" & path & "\"")
    elif l.startsWith("echo "):
      # Check for redirection
      let (cmd, file, op) = checkRedirection(l)
      if op != "":
        # Extract content from echo command
        var content = cmd[5..^1].strip()
        if (content.startsWith("\"") and content.endsWith("\"")) or (
            content.startsWith("'") and content.endsWith("'")):
          content = content[1..^2]

        if op == "write":
          res.add("  write \"" & file.replace("\"", "") & "\" \"" &
              escapeStringValue(content) & "\"")
        else:
          res.add("  append \"" & file.replace("\"", "") & "\" \"" &
              escapeStringValue(content) & "\"")
      else:
        var content = l[5..^1].strip()
        if (content.startsWith("\"") and content.endsWith("\"")) or (
            content.startsWith("'") and content.endsWith("'")):
          content = content[1..^2]
        res.add("  print \"" & escapeStringValue(content) & "\"")
    elif l.startsWith("export "):
      let parts = l[7..^1].split('=', 1)
      if parts.len == 2:
        var val = parts[1].strip()
        if val.startsWith("\"") and val.endsWith("\""):
          val = val[1..^2]
        elif val.startsWith("'") and val.endsWith("'"):
          val = val[1..^2]
        res.add("  env " & parts[0].strip() & " = \"" & escapeStringValue(val) & "\"")
      else:
        res.add("  # TODO: convert export " & l)
    elif l.startsWith("kpkgConfigure"):
      res.add("  macro build" & l[13..^1])
    else:
      let escaped = escapeStringValue(l)
      res.add("  exec \"" & escaped & "\"")

    inc i

  return res

# =============================================================================
# Run3 Generator
# =============================================================================

proc generateRun3(r2: Run2File): string =
  ## Generate Run3 format output from parsed Run2 file
  var s = ""

  if r2.pkg.len > 0: s.add("name: \"" & r2.pkg & "\"\n")
  if r2.version.len > 0: s.add("version: \"" & r2.version & "\"\n")
  if r2.release.len > 0: s.add("release: \"" & r2.release & "\"\n")
  if r2.epoch.len > 0 and r2.epoch != "no": s.add("epoch: \"" & r2.epoch & "\"\n")
  if r2.desc.len > 0: s.add("description: \"" & r2.desc & "\"\n")

  if r2.sources.len > 0:
    s.add("sources:\n")
    for src in r2.sources:
      s.add("  - \"" & src & "\"\n")

  if r2.sha256sum.len > 0:
    s.add("sha256sum:\n")
    for sum in r2.sha256sum:
      s.add("  - \"" & sum & "\"\n")

  if r2.sha512sum.len > 0:
    s.add("sha512sum:\n")
    for sum in r2.sha512sum:
      s.add("  - \"" & sum & "\"\n")

  if r2.b2sum.len > 0:
    s.add("b2sum:\n")
    for sum in r2.b2sum:
      s.add("  - \"" & sum & "\"\n")

  if r2.depends.len > 0:
    s.add("depends:\n")
    for dep in r2.depends:
      s.add("  - \"" & dep & "\"\n")

  if r2.buildDepends.len > 0:
    s.add("build_depends:\n")
    for dep in r2.buildDepends:
      s.add("  - \"" & dep & "\"\n")

  if r2.bootstrapDepends.len > 0:
    s.add("bootstrap_depends:\n")
    for dep in r2.bootstrapDepends:
      s.add("  - \"" & dep & "\"\n")

  if r2.optDepends.len > 0:
    s.add("opt_depends:\n")
    for dep in r2.optDepends:
      s.add("  - \"" & dep & "\"\n")

  if r2.conflicts.len > 0:
    s.add("conflicts:\n")
    for dep in r2.conflicts:
      s.add("  - \"" & dep & "\"\n")

  if r2.replaces.len > 0:
    s.add("replaces:\n")
    for dep in r2.replaces:
      s.add("  - \"" & dep & "\"\n")

  if r2.backup.len > 0:
    s.add("backup:\n")
    for f in r2.backup:
      s.add("  - \"" & f & "\"\n")

  if not r2.extract:
    s.add("extract: false\n")

  if r2.noChkupd:
    s.add("no_chkupd: true\n")

  if r2.isGroup:
    s.add("type: \"group\"\n")

  for pkg, deps in r2.extraDepends:
    s.add("depends_" & pkg & ":\n")
    for dep in deps:
      s.add("  - \"" & dep & "\"\n")

  s.add("\n")

  let lifecycleFuncs = @["build", "prepare", "check", "preupgrade",
      "preinstall", "package", "postinstall", "postupgrade", "postremove"]

  for fn in r2.functions:
    var isLifecycle = fn.name in lifecycleFuncs
    if fn.name.startsWith("package_"): isLifecycle = true

    if isLifecycle:
      s.add(fn.name & " {\n")
    else:
      s.add("func " & fn.name & " {\n")

    let convertedBody = convertFunctionBody(fn.body)
    for line in convertedBody:
      s.add(line & "\n")
    s.add("}\n\n")

  return s

# =============================================================================
# File Processing
# =============================================================================

proc convertFile(path: string, fromVer, toVer: int): tuple[output: string,
    error: string] =
  ## Convert a single file and return the output or error
  try:
    if fromVer == 2 and toVer == 3:
      let r2 = parseRun2(path)
      let output = generateRun3(r2)
      return (output, "")
    else:
      return ("", "unsupported conversion: " & $fromVer & " -> " & $toVer)
  except IOError as e:
    return ("", "cannot read file: " & e.msg)
  except CatchableError as e:
    return ("", "conversion error: " & e.msg)

proc processFile(filePath: string, fromVer, toVer: int, write,
    inPlace: bool): tuple[success: bool, error: string] =
  ## Process a single file with the specified output options
  let (output, error) = convertFile(filePath, fromVer, toVer)

  if error.len > 0:
    return (false, error)

  if inPlace:
    # Replace original file
    try:
      writeFile(filePath, output)
      return (true, "")
    except IOError as e:
      return (false, "cannot write file: " & e.msg)
  elif write:
    # Write to run3 file alongside original
    let dir = parentDir(filePath)
    let outPath = if dir.len > 0: dir / "run3" else: "run3"
    try:
      writeFile(outPath, output)
      return (true, "")
    except IOError as e:
      return (false, "cannot write file: " & e.msg)
  else:
    # Output to stdout
    echo output
    return (true, "")

proc getRun2FilePath(dirPath: string): string =
  ## Get the Run2 file path for a directory (returns "run" if it exists)
  let runPath = dirPath / "run"
  if fileExists(runPath):
    return runPath
  return ""

proc convertRun2ToRun3(path: string, write, inPlace, recursive: bool): int =
  ## Convert Run2 files to Run3 format
  var totalConverted = 0
  var totalErrors = 0
  var filesProcessed = 0

  let absPath = absolutePath(path)

  proc processEntry(filePath: string) =
    filesProcessed += 1
    let (success, error) = processFile(filePath, 2, 3, write, inPlace)
    if error.len > 0:
      totalErrors += 1
      styledEcho(fgRed, "error", fgDefault, ": ", filePath, ": ", error)
    elif success:
      totalConverted += 1
      if write or inPlace:
        let outDesc = if inPlace: "converted in-place" else: "wrote run3"
        styledEcho(fgGreen, outDesc, fgDefault, ": ", filePath)

  if fileExists(absPath):
    # Single file
    processEntry(absPath)
  elif dirExists(absPath):
    # Check for run file in directory
    let runPath = getRun2FilePath(absPath)

    if runPath.len > 0:
      processEntry(runPath)
    elif recursive:
      # Walk subdirectories
      for entry in walkDir(absPath):
        if entry.kind == pcDir and not isHidden(entry.path):
          let subRunPath = getRun2FilePath(entry.path)
          if subRunPath.len > 0:
            processEntry(subRunPath)
    else:
      styledEcho(fgRed, "error", fgDefault,
          ": no run file found in: ", absPath)
      return 1
  else:
    styledEcho(fgRed, "error", fgDefault, ": path does not exist: ", absPath)
    return 1

  # Summary (only when processing multiple files or using write/inPlace)
  if filesProcessed > 1 or (filesProcessed == 1 and (write or inPlace)):
    echo ""
    if totalErrors > 0:
      styledEcho(fgRed, $totalErrors, " error(s)", fgDefault,
          ", ", fgGreen, $totalConverted, " converted", fgDefault,
          " (", $filesProcessed, " file(s) processed)")
      return 1
    else:
      styledEcho(fgGreen, $totalConverted, " file(s) converted", fgDefault)
      return 0

  return if totalErrors > 0: 1 else: 0

# =============================================================================
# Main Entry Point
# =============================================================================

proc convert*(fromVer: int, toVer: int, path = ".", write = false,
    inPlace = false, recursive = true): int =
  ## Convert runfiles between format versions.
  ##
  ## fromVer: Source format version (e.g., 2 for Run2)
  ## toVer: Target format version (e.g., 3 for Run3)
  ## path: File or directory path to convert
  ## write: Write output to run3 file alongside original
  ## inPlace: Replace original file with converted output
  ## recursive: Process directories recursively

  # Validate mutually exclusive options
  if write and inPlace:
    styledEcho(fgRed, "error", fgDefault,
        ": --write and --inPlace cannot be used together")
    return 1

  # Validate version combination
  if fromVer == 2 and toVer == 3:
    return convertRun2ToRun3(path, write, inPlace, recursive)
  else:
    styledEcho(fgRed, "error", fgDefault,
        ": unsupported conversion from version ", $fromVer, " to ", $toVer)
    styledEcho(fgDefault, "Supported conversions:")
    styledEcho(fgDefault, "  2 -> 3  (Run2 to Run3)")
    return 1
