import cligen
import sequtils
import parsecfg
import os
import options
include ../kpkg/modules/logger
include ../kpkg/modules/config
include ../kpkg/build
include ../kpkg/update

proc debug(message: string) =
    when not defined(release):
        styledEcho "[", styleBlinkRapid, styleBright, fgYellow, " DEBUG ",
                resetStyle, "] "&message

proc info_msg(message: string) =
    styledEcho "[", styleBright, fgBlue, " INFO ", resetStyle, "] "&message

proc ok(message: string) =
    styledEcho "[", styleBright, fgGreen, " OK ", resetStyle, "] "&message

proc warn(message: string) =
    styledEcho "[", styleBright, fgYellow, " WARN ", resetStyle, "] "&message

proc error(message: string) =
    styledEcho "[", styleBright, fgRed, " ERROR ", resetStyle, "] "&message
    quit(1)
