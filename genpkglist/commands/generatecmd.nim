import os
import strutils
import ../../kpkg/modules/runparser


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

proc generateInternal(pkgPath = "", output = "out.md") =
  ## Generate a package markdown entry. 
 
  let pkg = parseRunfile(pkgPath, false)
  
  var finalText = "---"
  
  finalText = appendData(finalText, "title: "&pkg.pkg)
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
  finalText = finalText&"\nTo see the difference, see [The handbook](https://wiki.linux.kreato.dev/handbook/installation/#binary-vs-source)"

  writeFile(output, finalText)


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
        generateInternal(i.path, absolutePath(output)&"/"&lastPathPart(i.path)&".md")
  else:
    generateInternal(absolutePath(pkgPath), output)
