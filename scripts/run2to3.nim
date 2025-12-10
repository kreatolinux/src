import os, strutils, sequtils, tables, parsecfg

type
  Run2Function = object
    name: string
    body: seq[string]

  Run2File = object
    pkg: string
    version: string
    release: string
    epoch: string
    desc: string
    url: string # implied by sources
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
    # For specialized dependencies (DEPENDS_PKG)
    extraDepends: Table[string, seq[string]] 
    functions: seq[Run2Function]

proc isValidFunctionName(name: string): bool =
  if name.len == 0: return false
  let first = name[0]
  if not (first.isAlphaAscii or first == '_'): return false
  for c in name[1..^1]:
    if not (c.isAlphaNumeric or c == '_'): return false
  return true

proc parseRun2(path: string): Run2File =
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
    if '{' in stripped and not stripped.startsWith("if") and not stripped.startsWith("for") and not stripped.startsWith("else"): 
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
         if not bootstrapDependsExplicitlySet and ret.bootstrapDepends.len == 0 and op != "=":
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

# Check if a string is a heredoc start delimiter
# Returns (isHeredoc, delimiter)
proc checkHeredocStart(line: string): (bool, string) =
  let idx = line.find("<<")
  if idx == -1: return (false, "")
  
  var rest = line[idx+2..^1].strip()
  if rest.startsWith("-"): rest = rest[1..^1].strip()
  
  # Extract delimiter (handle quotes)
  var delim = rest.split(' ')[0] # naive split
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

proc convertFunctionBody(body: seq[string]): seq[string] =
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
      res.add(l)
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
        res.add("    write \"" & file.replace("\"", "") & "\" \"\"\"\n" & heredocContent & "\"\"\"")
      elif op == "append":
         res.add("    append \"" & file.replace("\"", "") & "\" \"\"\"\n" & heredocContent & "\"\"\"")
      else:
        var fullScript = l & "\n" & heredocContent & delim
        res.add("    exec \"\"\"\n" & fullScript & "\n\"\"\"")
      continue

    # Regular commands
    if l.startsWith("cd "):
      res.add("    cd \"" & l[3..^1] & "\"")
    elif l.startsWith("echo "):
      # Check for redirection
      let (cmd, file, op) = checkRedirection(l)
      if op != "":
         # Extract content from echo command
         # cmd is "echo something"
         var content = cmd[5..^1].strip()
         if (content.startsWith("\"") and content.endsWith("\"")) or (content.startsWith("'") and content.endsWith("'")):
           content = content[1..^2]
         
         if op == "write":
           res.add("    write \"" & file.replace("\"", "") & "\" \"" & content.replace("\"", "\\\"") & "\"")
         else:
           res.add("    append \"" & file.replace("\"", "") & "\" \"" & content.replace("\"", "\\\"") & "\"")
      else:
         var content = l[5..^1].strip()
         if (content.startsWith("\"") and content.endsWith("\"")) or (content.startsWith("'") and content.endsWith("'")):
           content = content[1..^2]
         res.add("    print \"" & content.replace("\"", "\\\"") & "\"")
    elif l.startsWith("export "):
      let parts = l[7..^1].split('=', 1)
      if parts.len == 2:
        res.add("    env " & parts[0] & "=\"" & parts[1].replace("\"", "") & "\"")
      else:
        res.add("    # TODO: convert export " & l)
    elif l == "make install":
      res.add("    exec make install")
    elif l.startsWith("ninja"):
      res.add("    exec " & l)
    elif l.startsWith("meson"):
      res.add("    exec " & l)
    elif l.startsWith("kpkgConfigure"):
      res.add("    macro build" & l[13..^1])
    else:
      let escaped = l.replace("\"", "\\\"")
      res.add("    exec \"" & escaped & "\"")
    
    inc i
      
  return res

proc generateRun3(r2: Run2File): string =
  var s = ""
  
  if r2.pkg.len > 0: s.add("name: \"" & r2.pkg & "\"\n")
  if r2.version.len > 0: s.add("version: \"" & r2.version & "\"\n")
  if r2.release.len > 0: s.add("release: \"" & r2.release & "\"\n")
  if r2.epoch.len > 0 and r2.epoch != "no": s.add("epoch: \"" & r2.epoch & "\"\n")
  if r2.desc.len > 0: s.add("description: \"" & r2.desc & "\"\n")
  
  if r2.sources.len > 0:
    s.add("sources:\n")
    for src in r2.sources:
      s.add("    - \"" & src & "\"\n")

  if r2.sha256sum.len > 0:
    s.add("sha256sum:\n")
    for sum in r2.sha256sum:
      s.add("    - \"" & sum & "\"\n")

  if r2.sha512sum.len > 0:
    s.add("sha512sum:\n")
    for sum in r2.sha512sum:
      s.add("    - \"" & sum & "\"\n")
      
  if r2.b2sum.len > 0:
    s.add("b2sum:\n")
    for sum in r2.b2sum:
      s.add("    - \"" & sum & "\"\n")

  if r2.depends.len > 0:
    s.add("depends:\n")
    for dep in r2.depends:
      s.add("    - \"" & dep & "\"\n")

  if r2.buildDepends.len > 0:
    s.add("build_depends:\n")
    for dep in r2.buildDepends:
      s.add("    - \"" & dep & "\"\n")

  if r2.bootstrapDepends.len > 0:
    s.add("bootstrap_depends:\n")
    for dep in r2.bootstrapDepends:
      s.add("    - \"" & dep & "\"\n")

  if r2.optDepends.len > 0:
    s.add("opt_depends:\n")
    for dep in r2.optDepends:
      s.add("    - \"" & dep & "\"\n")
      
  if r2.conflicts.len > 0:
    s.add("conflicts:\n")
    for dep in r2.conflicts:
      s.add("    - \"" & dep & "\"\n")

  if r2.replaces.len > 0:
    s.add("replaces:\n")
    for dep in r2.replaces:
      s.add("    - \"" & dep & "\"\n")

  if r2.backup.len > 0:
    s.add("backup:\n")
    for f in r2.backup:
      s.add("    - \"" & f & "\"\n")
      
  if not r2.extract:
    s.add("extract: false\n")
    
  if r2.noChkupd:
    s.add("no_chkupd: true\n")

  if r2.isGroup:
    s.add("is_group: true\n")
    
  for pkg, deps in r2.extraDepends:
    s.add("depends_" & pkg & ":\n")
    for dep in deps:
      s.add("    - \"" & dep & "\"\n")
      
  s.add("\n")
  
  let lifecycleFuncs = @["build", "prepare", "check", "preupgrade", "preinstall", "package", "postinstall", "postupgrade", "postremove"]
  
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

when isMainModule:
  if paramCount() < 1:
    echo "Usage: run2to3 <path_to_run_file>"
    quit(1)
    
  let path = paramStr(1)
  try:
    let r2 = parseRun2(path)
    echo generateRun3(r2)
  except Exception as e:
    echo "Error: " & e.msg
    quit(1)
