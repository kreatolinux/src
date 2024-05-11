import os
import logger
import streams
import strutils
import sequtils
import parsecfg

const overridesPath = "/etc/kpkg/override"

var override {.threadvar.}: Config

proc allOverrides*(): seq[string] =
  ## Returns all overrides.
  return toSeq(walkFiles(overridesPath&"/*.conf"))

proc getOverrideValue*(package: string, section: string, key: string, defaultVal = ""): string =
  ## Reads the override file and returns value of section.
  
  if fileExists(overridesPath&"/"&package&".conf"):
    override = loadConfig(overridesPath&"/"&package&".conf")
  else:
    err "internal: override file not found."
  
  return override.getSectionValue(section, key, defaultVal)

proc getOverrideSection*(package: string, section: string, defaultVal = ""): string =
  ## Reads the override file and returns value of section.
  if fileExists(overridesPath&"/"&package&".conf"):
    override = loadConfig(overridesPath&"/"&package&".conf")
  else:
    err "internal: override file not found."

  var fileStr = newFileStream(overridesPath&"/"&package&".conf", fmRead)
  var parser: CfgParser
  var res: string
  var reachedSection = false

  open(parser, fileStr, overridesPath)
  while true:
    var entry = next(parser)

    if entry.kind == cfgEof: break

    if reachedSection:
        if entry.kind == cfgKeyValuePair:
            if isEmptyOrWhitespace(res):
                res = entry.key & "=" & entry.value
            else:
                res.add("\n" & entry.key & "=" & entry.value)
        else:
            break

    if entry.kind == cfgSectionStart and entry.section == section:
        reachedSection = true

  return res

proc returnOverride*(package: string): string =
  ## Returns the full override file.
  if fileExists(overridesPath&"/"&package&".conf"):
    override = loadConfig(overridesPath&"/"&package&".conf")
  else:
    err "internal: override file not found."
  
  echo ($override).strip()
