import os
import strutils
import ../../kpkg/modules/runparser
import ../../kpkg/modules/dephandler


proc appendData(orig: string, str: string): string =
  # Appends data.
  # Made so the code doesn't look like a mess, and for convenience.
  return orig&"\n"&str

proc dependencyGenerator(deps: seq[string], pkgPath: string, text: string, isBuild: bool): string =
  # Generates the dependency listings.
  var finalText = text
  for i in deps:
    if fileExists(parentDir(pkgPath)&"/"&i&"/run"):
      let runfTemp = parseRunfile(parentDir(pkgPath)&"/"&i)
      if not isEmptyOrWhitespace(runfTemp.replaces.join("")):
        finalText = appendData(finalText, "- ["&i&"](../"&i&") or")
        for i in runfTemp.replaces:
          finalText = finalText&" ["&i&"](../"&i&")"&" or"
        finalText = finalText[0.. ^4]
      else:
        finalText = appendData(finalText, "- ["&i&"](../"&i&")")
       
    else:
      finalText = appendData(finalText, "- "&i)
  
    if isBuild:
      finalText = finalText&" (build)" 
  
  return finalText

proc generateInternal(pkgPath = "", output = "out.md"): bool =
  ## Generate a package markdown entry.
  ## Returns true if successful, false if skipped due to missing runfile.
 
  # Check if runfile exists before attempting to parse
  if not fileExists(pkgPath & "/run"):
    echo "WARNING: Skipping '" & pkgPath & "' - no runfile found"
    return false
  
  let pkg = parseRunfile(pkgPath, false)
  
  var finalText = "---"
  
  finalText = appendData(finalText, "title: "&pkg.pkg)
  finalText = appendData(finalText, "type: docs")
  finalText = appendData(finalText, "draft: false")
  finalText = appendData(finalText, "---\n")
  
  finalText = appendData(finalText, pkg.desc&"\n")

  finalText = appendData(finalText, "- version "&pkg.versionString)
  
  if pkg.isGroup:
    finalText = appendData(finalText, "- is a group package")
  else:
    finalText = appendData(finalText, "- is not a group package")
  
  if not isEmptyOrWhitespace(pkg.replaces.join("")):
    finalText = appendData(finalText, "- replaces "&pkg.replaces.join(" ,"))
  
  if not isEmptyOrWhitespace(pkg.conflicts.join("")):
    finalText = appendData(finalText, "- conflicts "&pkg.replaces.join(" ,"))

  finalText = appendData(finalText, "\n# Dependencies")
  
  if isEmptyOrWhitespace(pkg.deps.join("")) and isEmptyOrWhitespace(pkg.bdeps.join("")):
    finalText = appendData(finalText, "No dependencies")
  else:
    finalText = dependencyGenerator(pkg.deps, pkgPath, finalText, false)
    finalText = dependencyGenerator(pkg.bdeps, pkgPath, finalText, true)

  #finalText = appendData(finalText, "# Required by") # todo

  finalText = appendData(finalText, "\n# Installation\n")
  finalText = appendData(finalText, "Install it by running either;\n")
  finalText = appendData(finalText, "```\nkpkg install "&lastPathPart(pkgPath)&"\n```")
  finalText = appendData(finalText, "\nor\n")
  finalText = appendData(finalText, "```\nkpkg build "&lastPathPart(pkgPath)&"\n```")
  finalText = finalText&"\nTo see the difference, see [The handbook](https://linux.krea.to/docs/handbook/installation/#binary-vs-source)"

  # Generate dependency graph visualization
  finalText = appendData(finalText, "\n# Dependency Graph\n")
  
  let ctx = dependencyContext(
    root: "/",
    isBuild: false,
    useBootstrap: false,
    ignoreInit: true,
    ignoreCircularDeps: true,
    forceInstallAll: false,
    init: ""
  )
  
  let graph = buildDependencyGraph(@[pkgPath], ctx, isInstallDir = true)
  let mermaidChart = generateMermaidChart(graph, @[lastPathPart(pkgPath)])
  
  finalText = appendData(finalText, "```mermaid")
  finalText = finalText&"\n"&mermaidChart
  finalText = finalText&"```"

  writeFile(output, finalText)
  return true


proc generate*(pkgPath = "", output = "", all = false, verbose = false) =
  ## Generate package markdown entries.   
  if not dirExists(pkgPath):
    echo "ERROR: Enter a path with --pkgPath to continue"
    quit(1) # Add a helpful error message
  
  if all:
    for i in walkDir(absolutePath(pkgPath)):
      if not isHidden(i.path) and dirExists(i.path):
        if verbose:
          echo "DEBUG: Now generating '"&absolutePath(output)&"/"&lastPathPart(i.path)&".md"&"' with '"&i.path&"'"
        discard generateInternal(i.path, absolutePath(output)&"/"&lastPathPart(i.path)&".md")
  else:
    discard generateInternal(absolutePath(pkgPath), output)
