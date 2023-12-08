import os
import config

proc crossCompilerExists*(target: string): bool =
    # Checks if a target is already available.
    if dirExists("/var/cache/kpkg/installed/"&target&"-"&getConfigValue("Options", "cc", "cc")):
        return true
    else:
        return false