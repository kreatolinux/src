import os
import logger
import parsecfg
import sequtils
import strutils
import tables
import run3/run3
import run3/parser
import run3/variables

type
  SourceEntry* = tuple
    url: string
    sha256sum: string
    sha512sum: string
    b2sum: string

type runFile* = object
  pkg*: string
  sources*: seq[SourceEntry]
  version*: string
  release*: string
  extract*: bool = true
  autocd*: bool = true
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
  license*: seq[string]
  noChkupd*: bool
  isGroup*: bool
  isParsed*: bool
  isSemver*: bool = false
  run3Data*: Run3File ## Parsed run3 representation
  functions*: seq[tuple[name: string, body: string]]

proc parseRunfile*(path: string, removeLockfileWhenErr = true): runFile =
  ## Parse a run3 file into a runFile object.

  var ret: runFile
  ret.functions = @[]
  let package = lastPathPart(path)
  var override: Config

  debug "parseRunfile: starting parse for '"&package&"'"

  if fileExists("/etc/kpkg/override/"&package&".conf"):
    override = loadConfig("/etc/kpkg/override/"&package&".conf")
  else:
    override = newConfig()

  try:
    # Use run3 parser
    debug "parseRunfile: calling run3.parseRun3"
    let rf = run3.parseRun3(path)
    debug "parseRunfile: run3.parseRun3 completed"
    ret.run3Data = rf
    debug "parseRunfile: getting all variables"
    let allVars = rf.getAllVariables()
    debug "parseRunfile: got all variables"

    ret.pkg = rf.getVariable("name", override, "runFile", "name")
    ret.desc = rf.getVariable("description", override, "runFile", "description")
    ret.version = rf.getVariable("version", override, "runFile", "version")
    ret.release = rf.getVariable("release", override, "runFile", "release")

    # Parse sources and checksums into SourceEntry tuples
    let sourceUrls = rf.getListVariable("sources", override, "runFile", "sources")
    let sha256sums = rf.getListVariable("sha256sum", override, "runFile", "sha256sum")
    let sha512sums = rf.getListVariable("sha512sum", override, "runFile", "sha512sum")
    let b2sums = rf.getListVariable("b2sum", override, "runFile", "b2sum")

    ret.sources = @[]
    for i, url in sourceUrls:
      let entry: SourceEntry = (
        url: url,
        sha256sum: if i < sha256sums.len: sha256sums[i] else: "",
        sha512sum: if i < sha512sums.len: sha512sums[i] else: "",
        b2sum: if i < b2sums.len: b2sums[i] else: ""
      )
      ret.sources.add(entry)

    let noChkupdStr = rf.getVariable("no_chkupd", override, "runFile", "noChkupd")
    if noChkupdStr != "": ret.noChkupd = parseBool(noChkupdStr)

    let isSemverStr = rf.getVariable("is_semver", override, "runFile", "isSemver")
    if isSemverStr != "": ret.isSemver = parseBool(isSemverStr)

    ret.epoch = rf.getVariable("epoch", override, "runFile", "epoch")

    ret.backup = rf.getListVariable("backup", override, "runFile", "backup")

    ret.conflicts = rf.getListVariable("conflicts", override, "runFile", "conflicts")
    ret.deps = rf.getListVariable("depends", override, "runFile", "depends")
    ret.bdeps = rf.getListVariable("build_depends", override, "runFile", "buildDepends")

    # Bootstrap depends logic

    # Determine variable name for bootstrap dependencies
    var bsdepsName = "bootstrap_depends"
    if not allVars.hasKey("bootstrap_depends") and allVars.hasKey("build_depends"):
      bsdepsName = "build_depends"

    ret.bsdeps = rf.getListVariable(bsdepsName, override, "runFile", "bootstrapDepends")


    # Optdepends

    # Check variable existence order
    var optVarName = ""
    if allVars.hasKey("optdepends"): optVarName = "optdepends"
    elif allVars.hasKey("opt_depends"): optVarName = "opt_depends"
    elif allVars.hasKey("opt-depends"): optVarName = "opt-depends"

    # Construct raw value joined with " ;; " for override check
    var optVal = ""
    if optVarName != "":
      let v = allVars[optVarName]
      if v.isList:
        optVal = v.toList().join(" ;; ")
      else:
        optVal = v.toString()

    let optOverridden = override.getSectionValue("runFile", "optDepends", optVal)

    # Use list directly if not overridden
    if optOverridden == optVal and optVarName != "" and allVars[
            optVarName].isList:
      var res: seq[string] = @[]
      for item in allVars[optVarName].toList():
        res.add(rf.substituteVariables(item))
      ret.optdeps = res
    else:
      let optSub = rf.substituteVariables(optOverridden)
      if optSub.len > 0:
        ret.optdeps = optSub.split(" ;; ")
        ret.optdeps.keepItIf(it.len > 0)
      else:
        ret.optdeps = @[]

    let isGroupStr = rf.getVariable("is_group", override, "runFile", "isGroup")
    if isGroupStr != "": ret.isGroup = parseBool(isGroupStr)

    let extractStr = rf.getVariable("extract", override, "runFile", "extract")
    if extractStr != "": ret.extract = parseBool(extractStr)
    else: ret.extract = true

    # Parse autocd - defaults to true, but if extract is false and autocd not set, defaults to false
    let autocdStr = rf.getVariable("autocd", override, "runFile", "autocd")
    if autocdStr != "":
      ret.autocd = parseBool(autocdStr)
    else:
      # If autocd not explicitly set, default based on extract
      ret.autocd = ret.extract

    ret.replaces = rf.getListVariable("replaces", override, "runFile", "replaces")

    ret.license = rf.getListVariable("license", override, "runFile", "license")

    # Handle depends_package logic
    let p = replace(package, '-', '_')
    let pLower = p.toLowerAscii()

    for key, val in allVars:
      let kLower = key.toLowerAscii()
      if kLower == "depends_" & pLower or kLower == "depends-" & pLower or
              kLower == "depends" & pLower:
        let extra = rf.getListVariable(key)
        ret.deps.add(extra)
      elif kLower == "bootstrap_depends_" & pLower or kLower ==
              "bootstrap-depends-" & pLower or kLower ==
              "bootstrapdepends" & pLower:
        let extra = rf.getListVariable(key)
        ret.bsdeps.add(extra)

    # Functions
    for fnName in rf.getAllFunctions():
      ret.functions.add((name: fnName, body: ""))

    # Custom functions
    for fnName in rf.getAllCustomFunctions():
      ret.functions.add((name: fnName, body: ""))

  except IOError:
    if removeLockfileWhenErr:
      fatal(path&" doesn't seem to have a run3 file. possibly a broken package?")
    else:
      error(path&" doesn't seem to have a run3 file. possibly a broken package?")
      quit(1)
  except ParseError as e:
    if removeLockfileWhenErr:
      fatal(path&"/run3 parse error at line "&($e.line)&", column "&(
          $e.col)&": "&e.msg)
    else:
      error(path&"/run3 parse error at line "&($e.line)&", column "&(
          $e.col)&": "&e.msg)
      quit(1)
  except CatchableError:
    if removeLockfileWhenErr:
      fatal(path&" error parsing run3 file: "&getCurrentExceptionMsg())
    else:
      error(path&" error parsing run3 file: "&getCurrentExceptionMsg())
      quit(1)

  # Calculate versionString
  if ret.epoch != "" and ret.epoch != "no":
    ret.versionString = ret.version&"-"&ret.release&"-"&ret.epoch
  else:
    ret.versionString = ret.version&"-"&ret.release
    ret.epoch = "no"

  ret.isParsed = true
  return ret
